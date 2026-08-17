import Foundation

public struct ClientHealth: Sendable, Equatable {
    public var healthy: Bool
    public var error: String?
    public var lastSync: Date?
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
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private var listeners: [UUID: @Sendable (Library) -> Void] = [:]

    public init(store: Store, adapters: [any ClientAdapter], backups: BackupStore, gatewayPort: Int) {
        self.store = store; self.adapters = adapters; self.backups = backups; self.gatewayPort = gatewayPort
    }

    public func currentLibrary() -> Library { library }
    public func clientHealth() -> [ClientID: ClientHealth] { health }

    /// Called on any change to the library (after sync). Returns a token to remove later.
    public func addListener(_ f: @escaping @Sendable (Library) -> Void) -> UUID {
        let id = UUID(); listeners[id] = f; return id
    }
    public func removeListener(_ id: UUID) { listeners[id] = nil }

    /// Load library from disk (throws if corrupt), read all clients, plan, write. Returns the plan.
    @discardableResult
    public func runOnce(now: Date = .init()) async throws -> SyncOutput {
        library = try store.load()
        return try sync(now: now)
    }

    /// Apply a change to the library, then sync it out. The library change is intentional, so the
    /// "client wins on presence" rule is skipped for this pass (otherwise enabling a server for a
    /// client whose file doesn't have it yet would be immediately undone).
    public func mutate(_ f: (inout Library) throws -> Void) async throws {
        try f(&library)
        try store.save(library)
        _ = try sync(skipPresence: true)
    }

    private func sync(now: Date = .init(), skipPresence: Bool = false) throws -> SyncOutput {
        var snapshots: [ClientID: [ExternalServer]] = [:]
        for a in adapters where a.isInstalled() {
            do {
                snapshots[a.id] = try a.parse(try a.readData())
                health[a.id] = ClientHealth(healthy: true, error: nil, lastSync: now)
            } catch {
                health[a.id] = ClientHealth(healthy: false, error: String(describing: error), lastSync: health[a.id]?.lastSync)
            }
        }
        let suppressed = skipPresence ? Set(snapshots.keys) : Set(suppressedUntil.filter { $0.value > now }.keys)
        let out = SyncEngine.plan(SyncInput(library: library, snapshots: snapshots, suppressed: suppressed,
                                            gatewayPort: gatewayPort, now: now))
        if out.library != library {
            library = out.library
            try store.save(library)
        }
        for (client, desired) in out.writes {
            guard let a = adapters.first(where: { $0.id == client }) else { continue }
            let current = try a.readData()
            let data = try a.render(desired, over: current)
            guard data != current else { continue }
            try backups.backup(a.configPath, for: client, at: now)
            try AtomicFile.write(data, to: a.configPath)
            suppressedUntil[client] = now.addingTimeInterval(suppressWindow)
        }
        for l in listeners.values { l(library) }
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
                _ = try? await self.runOnce()
            }
        }
    }

    public func stopWatching() {
        watcher?.stop(); watcher = nil
        watchTask?.cancel(); watchTask = nil
    }
}
