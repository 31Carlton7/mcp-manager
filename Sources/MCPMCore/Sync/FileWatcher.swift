import Foundation

/// Watches each client's config file for outside edits.
///
/// Two kinds of source are needed. A directory source catches the file appearing, vanishing, or
/// being swapped by an atomic replace — the case a source bound to the old inode would miss. A
/// per-file source catches an editor rewriting the file in place, which changes no directory
/// entry. Every event re-stamps the target and reports only clients whose mtime/size/inode
/// actually moved, debounced per client so a burst of writes collapses into one.
///
/// All mutable state is confined to `queue`.
public final class FileWatcher: @unchecked Sendable {
    struct Stamp: Equatable {
        var mtime: TimeInterval = 0
        var size: Int = 0
        var inode: Int = 0
    }

    private let paths: [ClientID: URL]
    private let debounce: Duration
    private let queue = DispatchQueue(label: "co.charmtechnologies.mcpm.watch")
    private var dirSources: [DispatchSourceFileSystemObject] = []
    private var fileSources: [ClientID: DispatchSourceFileSystemObject] = [:]
    private var stamps: [ClientID: Stamp] = [:]
    private var pending: [ClientID: DispatchWorkItem] = [:]
    private var continuation: AsyncStream<ClientID>.Continuation?

    public init(paths: [ClientID: URL], debounce: Duration = .milliseconds(500)) {
        self.paths = paths; self.debounce = debounce
    }

    /// Live source count, for tests asserting that re-arming doesn't accumulate descriptors.
    var sourceCount: Int { queue.sync { dirSources.count + fileSources.count } }

    public func start() -> AsyncStream<ClientID> {
        let (stream, cont) = AsyncStream<ClientID>.makeStream()
        queue.sync {
            continuation = cont
            for (client, url) in paths { stamps[client] = Self.stamp(url) }
            let dirs = Dictionary(grouping: paths.keys, by: { paths[$0]!.deletingLastPathComponent().path })
            for (dir, clients) in dirs {
                let fd = open(dir, O_EVTONLY)
                guard fd >= 0 else { continue }
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
                src.setEventHandler { [weak self] in self?.check(clients) }
                src.setCancelHandler { close(fd) }
                src.resume()
                dirSources.append(src)
            }
            for client in paths.keys { armFile(client) }
        }
        return stream
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

    /// All zeroes when the file doesn't exist.
    static func stamp(_ url: URL) -> Stamp {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return Stamp() }
        return Stamp(mtime: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     size: (a[.size] as? Int) ?? 0,
                     inode: (a[.systemFileNumber] as? Int) ?? 0)
    }

    public func stop() {
        queue.sync {
            dirSources.forEach { $0.cancel() }
            dirSources.removeAll()
            fileSources.values.forEach { $0.cancel() }
            fileSources.removeAll()
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
            continuation?.finish()
        }
    }
}
