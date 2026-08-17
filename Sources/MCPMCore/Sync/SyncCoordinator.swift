import Foundation

public enum SyncCoordinatorError: Error, Equatable {
    /// A mutation was attempted before the library was ever read successfully. Saving now would
    /// overwrite a store we failed to load — usually a corrupt one the user still wants back.
    case notLoaded
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
    public let backups: BackupStore
    public var gatewayPort: Int
    private let suppressWindow: TimeInterval = 2
    private var suppressedUntil: [ClientID: Date] = [:]
    private var health: [ClientID: ClientHealth] = [:]
    private var library = Library()
    /// Set once `store.load()` has succeeded. Until then the in-memory library is a placeholder
    /// and must never be written back.
    private var loaded = false
    public private(set) var lastError: String?
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private var listeners: [UUID: @Sendable (Library) -> Void] = [:]

    public init(store: Store, adapters: [any ClientAdapter], backups: BackupStore, gatewayPort: Int) {
        self.store = store; self.adapters = adapters; self.backups = backups; self.gatewayPort = gatewayPort
    }

    public func currentLibrary() -> Library { library }
    public func lastSyncError() -> String? { lastError }

    /// Health of the clients that are installed right now.
    public func clientHealth() -> [ClientID: ClientHealth] {
        let installed = Set(adapters.filter { $0.isInstalled() }.map(\.id))
        return health.filter { installed.contains($0.key) }
    }

    /// Called on any change to the library (after sync). Returns a token to remove later.
    public func addListener(_ f: @escaping @Sendable (Library) -> Void) -> UUID {
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
    public func mutate(_ f: (inout Library) throws -> Void) async throws {
        guard loaded else { throw SyncCoordinatorError.notLoaded }
        let before = library
        try f(&library)
        try store.save(library)
        _ = try sync(skipPresence: true, alreadyChanged: library != before)
    }

    /// `alreadyChanged` reports an edit made to `library` before this pass, so listeners still hear
    /// about a mutation that the plan itself leaves untouched.
    private func sync(now: Date = .init(), skipPresence: Bool = false,
                      alreadyChanged: Bool = false) throws -> SyncOutput {
        lastError = nil
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
        let suppressed = skipPresence ? Set(snapshots.keys) : Set(suppressedUntil.filter { $0.value > now }.keys)
        let out = SyncEngine.plan(SyncInput(library: library, snapshots: snapshots, suppressed: suppressed,
                                            gatewayPort: gatewayPort, now: now))
        let planChanged = out.library != library
        if planChanged {
            library = out.library
            try store.save(library)
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

        // Off the actor, so one slow listener can't stall the next sync.
        if planChanged || alreadyChanged {
            let lib = library
            for l in listeners.values { Task { l(lib) } }
        }
        return out
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
