import Foundation

public enum SyncCoordinatorError: Error, Equatable, CustomStringConvertible {
    /// A mutation was attempted before the library was ever read successfully. Saving now would
    /// overwrite a store we failed to load — usually a corrupt one the user still wants back.
    case notLoaded
    /// A mutation was attempted while the first import is still unconfirmed. Nothing may be
    /// written until the user has seen what the import would do.
    case readOnly

    public var description: String {
        switch self {
        case .notLoaded: "library not loaded (see lastError)"
        case .readOnly: "setup is not finished — confirm the first import before changing anything"
        }
    }
}

public struct ClientHealth: Sendable, Equatable {
    public var healthy: Bool
    public var error: String?
    public var lastSync: Date?
    /// False when nothing about this client's config file can be observed. Always true while the
    /// coordinator isn't watching.
    public var watched: Bool = true
}

public actor SyncCoordinator {
    public let store: Store
    public let adapters: [any ClientAdapter]
    public private(set) var backups: BackupStore
    public var gatewayPort: Int
    private let suppressWindow: TimeInterval = 2
    private var suppressedUntil: [ClientID: Date] = [:]
    private var health: [ClientID: ClientHealth] = [:]
    private var library = Library()
    /// Set once `store.load()` has succeeded. Until then the in-memory library is a placeholder
    /// and must never be written back.
    private var loaded = false
    /// Look, don't touch: every pass still reads and plans, but the library is not saved and no
    /// client file is written. This is what the daemon runs in until the user has confirmed the
    /// first import — see `Settings.importConfirmed`.
    public private(set) var readOnly: Bool
    public private(set) var lastError: String?
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private var listeners: [UUID: @Sendable (Snapshot) -> Void] = [:]

    /// Everything a subscriber needs, read in one actor hop so the pieces can't disagree.
    public struct Snapshot: Sendable {
        public var library: Library
        /// Health of the clients installed at the time of the read.
        public var health: [ClientID: ClientHealth]
        public var lastError: String?
    }

    /// The parts of health worth telling a subscriber about. `lastSync` is left out on purpose: it
    /// moves on every pass, so counting it would turn every sync into an event.
    private struct HealthKey: Equatable {
        var healthy: Bool
        var watched: Bool
        var error: String?
        init(_ h: ClientHealth) { healthy = h.healthy; watched = h.watched; error = h.error }
    }

    public init(store: Store, adapters: [any ClientAdapter], backups: BackupStore, gatewayPort: Int,
                readOnly: Bool = false) {
        self.store = store; self.adapters = adapters; self.backups = backups; self.gatewayPort = gatewayPort
        self.readOnly = readOnly
    }

    /// Flipped off once the user confirms the first import; nothing flips it back on. The caller
    /// is expected to `runOnce()` afterwards — this only lifts the block, it does not sync.
    public func setReadOnly(_ value: Bool) { readOnly = value }

    public func currentLibrary() -> Library { library }

    public func snapshot() -> Snapshot {
        Snapshot(library: library, health: clientHealth(), lastError: lastError)
    }

    /// Health of the clients that are installed right now.
    public func clientHealth() -> [ClientID: ClientHealth] {
        let installed = Set(adapters.filter { $0.isInstalled() }.map(\.id))
        return health.filter { installed.contains($0.key) }
    }

    /// How many backups of each client config to keep. Settable while the daemon runs: the count
    /// only decides what `backup` prunes on the next write, so nothing already on disk depends on
    /// the old value.
    public func setBackupRetention(_ keep: Int) {
        backups = BackupStore(root: backups.root, keep: keep)
    }

    /// Drop the "we just wrote this file" window for a client, so the next pass reads it back even
    /// if the daemon wrote it moments ago. For a re-import the user asked for.
    public func clearSuppression(for client: ClientID) { suppressedUntil[client] = nil }

    /// Called after a sync that changed the library, a client's health, or the last error. Returns
    /// a token to remove later.
    public func addListener(_ f: @escaping @Sendable (Snapshot) -> Void) -> UUID {
        let id = UUID(); listeners[id] = f; return id
    }
    public func removeListener(_ id: UUID) { listeners[id] = nil }

    /// Load library from disk (throws if corrupt), read all clients, plan, write. Returns the plan.
    @discardableResult
    public func runOnce(now: Date = .init()) async throws -> SyncOutput {
        do {
            library = try store.load()
            loaded = true
        } catch {
            lastError = String(describing: error)
            throw error
        }
        return try sync(now: now)
    }

    /// Apply a change to the library, then sync it out. The library change is intentional, so the
    /// "client wins on presence" rule is skipped for this pass (otherwise enabling a server for a
    /// client whose file doesn't have it yet would be immediately undone).
    ///
    /// The closure's return value comes back to the caller, so a mutation that mints something —
    /// an id, say — can hand it out without a second read that another mutation could slip into.
    @discardableResult
    public func mutate<T: Sendable>(_ f: (inout Library) throws -> T) async throws -> T {
        guard loaded else { throw SyncCoordinatorError.notLoaded }
        guard !readOnly else { throw SyncCoordinatorError.readOnly }
        let before = library
        let result = try f(&library)
        try store.save(library)
        _ = try sync(skipPresence: true, alreadyChanged: library != before)
        return result
    }

    /// `alreadyChanged` reports an edit made to `library` before this pass, so listeners still hear
    /// about a mutation that the plan itself leaves untouched.
    private func sync(now: Date = .init(), skipPresence: Bool = false,
                      alreadyChanged: Bool = false) throws -> SyncOutput {
        let healthBefore = health.mapValues(HealthKey.init)
        let errorBefore = lastError
        lastError = nil
        let (snapshots, reads) = readClients(now: now)
        let suppressed = skipPresence ? Set(snapshots.keys) : Set(suppressedUntil.filter { $0.value > now }.keys)
        let out = SyncEngine.plan(SyncInput(library: library, snapshots: snapshots, suppressed: suppressed,
                                            gatewayPort: gatewayPort, now: now))

        // The plan and the health this pass gathered are still worth returning; see `readOnly`.
        guard !readOnly else {
            notifyIfChanged(healthBefore: healthBefore, errorBefore: errorBefore,
                            planChanged: false, alreadyChanged: alreadyChanged)
            return out
        }

        let planChanged = out.library != library
        if planChanged {
            library = out.library
            do {
                try store.save(library)
            } catch {
                lastError = String(describing: error)
                throw error
            }
        }

        // A client that can't be written is that client's problem: record it and carry on, since
        // the library is already saved and the other clients still deserve their update.
        var failures: [String] = []
        for (client, desired) in out.writes {
            guard let a = adapters.first(where: { $0.id == client }) else { continue }
            do {
                let current = reads[client] ?? nil
                let data = try a.render(desired, over: current)
                guard data != current else { continue }
                try backups.backup(a.configPath, for: client, at: now)
                try AtomicFile.write(data, to: a.configPath)
                // Timed from the write, not from the start of the pass, so a slow pass doesn't
                // eat into the window in which our own write comes back at us as a file event.
                suppressedUntil[client] = Date().addingTimeInterval(suppressWindow)
            } catch {
                health[client] = ClientHealth(healthy: false, error: String(describing: error),
                                              lastSync: health[client]?.lastSync,
                                              watched: health[client]?.watched ?? true)
                failures.append("\(client.rawValue): \(error)")
            }
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "; ") }

        notifyIfChanged(healthBefore: healthBefore, errorBefore: errorBefore,
                        planChanged: planChanged, alreadyChanged: alreadyChanged)
        return out
    }

    /// Reads every installed client, recording health as it goes. Returns what parsed, and the raw
    /// bytes behind it so a write can be compared against what is already on disk.
    private func readClients(now: Date) -> (snapshots: [ClientID: [ExternalServer]], reads: [ClientID: Data?]) {
        let unwatched = Set(watcher?.unwatched() ?? [])
        var snapshots: [ClientID: [ExternalServer]] = [:]
        var reads: [ClientID: Data?] = [:]
        for a in adapters where a.isInstalled() {
            do {
                let data = try a.readData()
                snapshots[a.id] = try a.parse(data)
                reads.updateValue(data, forKey: a.id)
                health[a.id] = ClientHealth(healthy: true, error: nil, lastSync: now,
                                            watched: !unwatched.contains(a.id))
            } catch {
                health[a.id] = ClientHealth(healthy: false, error: String(describing: error),
                                            lastSync: health[a.id]?.lastSync, watched: !unwatched.contains(a.id))
            }
        }
        return (snapshots, reads)
    }

    /// Health and the last error are as much a part of what subscribers show as the library is,
    /// so a pass that only turns a client red still has something to say.
    private func notifyIfChanged(healthBefore: [ClientID: HealthKey], errorBefore: String?,
                                 planChanged: Bool, alreadyChanged: Bool) {
        guard planChanged || alreadyChanged
                || health.mapValues(HealthKey.init) != healthBefore || lastError != errorBefore else { return }
        // Off the actor, so one slow listener can't stall the next sync.
        let snap = snapshot()
        for l in listeners.values { Task { l(snap) } }
    }

    /// What a sync would do right now, without doing any of it: the plan, plus the snapshots it
    /// was planned against so a caller can say which entries a write would add, drop or reshape.
    ///
    /// Deliberately ignores the suppression window. This answers a question a human asked, not one
    /// the watcher asked, so a file we happen to have written seconds ago is still fair to read.
    public func plannedChanges(now: Date = .init()) -> (plan: SyncOutput, snapshots: [ClientID: [ExternalServer]]) {
        let (snapshots, _) = readClients(now: now)
        let out = SyncEngine.plan(SyncInput(library: library, snapshots: snapshots, suppressed: [],
                                            gatewayPort: gatewayPort, now: now))
        return (out, snapshots)
    }

    /// Watch client config files and re-sync on change. Idempotent.
    public func startWatching() {
        guard watcher == nil else { return }
        let paths = Dictionary(uniqueKeysWithValues: adapters.filter { $0.isInstalled() }.map { ($0.id, $0.configPath) })
        let w = FileWatcher(paths: paths)
        watcher = w
        let stream = w.start()
        watchTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                do { _ = try await self.runOnce() }
                catch { await self.setLastError(String(describing: error)) }
            }
        }
    }

    private func setLastError(_ message: String) { lastError = message }

    public func stopWatching() {
        watcher?.stop(); watcher = nil
        watchTask?.cancel(); watchTask = nil
    }
}
