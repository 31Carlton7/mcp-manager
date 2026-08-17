import Foundation

/// Watches each client's config file for outside edits.
///
/// Two kinds of source are needed. A directory source catches the file appearing, vanishing, or
/// being swapped by an atomic replace — the case a source bound to the old inode would miss. A
/// per-file source catches an editor rewriting the file in place, which changes no directory
/// entry. Every event re-stamps the target and reports only clients whose mtime/size/inode
/// actually moved, debounced per client so a burst of writes collapses into one.
///
/// A client whose config directory doesn't exist yet is watched at its nearest existing ancestor,
/// and the watch walks back down as the real directory appears.
///
/// All mutable state is confined to `queue`.
public final class FileWatcher: @unchecked Sendable {
    struct Stamp: Equatable {
        var mtime: TimeInterval = 0
        var size: Int = 0
        var inode: Int = 0
    }

    private struct DirWatch {
        var source: DispatchSourceFileSystemObject
        /// The directory actually open — the intended one, or an ancestor standing in for it.
        var watching: String
    }

    private let paths: [ClientID: URL]
    private let debounce: Duration
    private let queue = DispatchQueue(label: "co.charmtechnologies.mcpm.watch")
    /// Keyed by the *intended* config directory, which may not exist yet.
    private var dirWatches: [String: DirWatch] = [:]
    private var dirClients: [String: [ClientID]] = [:]
    private var fileSources: [ClientID: DispatchSourceFileSystemObject] = [:]
    private var stamps: [ClientID: Stamp] = [:]
    private var pending: [ClientID: DispatchWorkItem] = [:]
    private var continuation: AsyncStream<ClientID>.Continuation?
    private var stream: AsyncStream<ClientID>?

    public init(paths: [ClientID: URL], debounce: Duration = .milliseconds(500)) {
        self.paths = paths; self.debounce = debounce
    }

    /// Live source count, for tests asserting that re-arming doesn't accumulate descriptors.
    var sourceCount: Int { queue.sync { dirWatches.count + fileSources.count } }

    /// Clients with no directory source at all — nothing about them can be observed. Empty in the
    /// normal case, including when the config directory is missing but an ancestor stands in.
    public func unwatched() -> [ClientID] {
        queue.sync {
            paths.keys
                .filter { dirWatches[paths[$0]!.deletingLastPathComponent().path] == nil }
                .sorted()
        }
    }

    /// Idempotent: starting an already-started watcher returns the stream it already handed out.
    public func start() -> AsyncStream<ClientID> {
        queue.sync {
            if let stream { return stream }
            let (s, cont) = AsyncStream<ClientID>.makeStream()
            stream = s
            continuation = cont
            for (client, url) in paths { stamps[client] = Self.stamp(url) }
            dirClients = Dictionary(grouping: paths.keys, by: { paths[$0]!.deletingLastPathComponent().path })
            for dir in dirClients.keys { armDir(dir) }
            for client in paths.keys { armFile(client) }
            return s
        }
    }

    /// Binds a source to `intended`, or to its nearest existing ancestor when it doesn't exist yet.
    /// Re-run on every event so the watch can walk back down once the real directory appears.
    private func armDir(_ intended: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let target = Self.nearestExistingDirectory(intended) else {
            dirWatches.removeValue(forKey: intended)?.source.cancel()
            return
        }
        if dirWatches[intended]?.watching == target { return }
        dirWatches.removeValue(forKey: intended)?.source.cancel()
        let fd = open(target, O_EVTONLY)
        guard fd >= 0 else { return }
        let clients = dirClients[intended] ?? []
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.armDir(intended)
            self.check(clients)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatches[intended] = DirWatch(source: src, watching: target)
    }

    /// Binds a source to the file itself. Must be re-run whenever the file is replaced, since the
    /// old descriptor follows the old inode. A missing file is left to the directory source.
    private func armFile(_ client: ClientID) {
        dispatchPrecondition(condition: .onQueue(queue))
        fileSources.removeValue(forKey: client)?.cancel()
        guard let url = paths[client] else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
        src.setEventHandler { [weak self] in self?.check([client]) }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSources[client] = src
    }

    private func check(_ clients: [ClientID]) {
        dispatchPrecondition(condition: .onQueue(queue))
        for c in clients {
            let s = Self.stamp(paths[c]!)
            guard s != stamps[c] else { continue }
            if s.inode != stamps[c]?.inode { armFile(c) }
            stamps[c] = s
            pending[c]?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.continuation?.yield(c) }
            pending[c] = item
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.millis(debounce)), execute: item)
        }
    }

    static func millis(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }

    /// `path` itself if it's an existing directory, else the closest ancestor that is one.
    static func nearestExistingDirectory(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while true {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// All zeroes when the file doesn't exist.
    static func stamp(_ url: URL) -> Stamp {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return Stamp() }
        return Stamp(mtime: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     size: (a[.size] as? Int) ?? 0,
                     inode: (a[.systemFileNumber] as? Int) ?? 0)
    }

    public func stop() {
        queue.sync {
            dirWatches.values.forEach { $0.source.cancel() }
            dirWatches.removeAll()
            fileSources.values.forEach { $0.cancel() }
            fileSources.removeAll()
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
            continuation?.finish()
            continuation = nil
            stream = nil
        }
    }
}
