import Foundation

/// Watches each client's config file for outside edits.
///
/// Watching the *directory* (not the file) survives editors and our own atomic replace, both of
/// which swap in a new inode rather than writing in place. Each event re-stamps the target files
/// and only reports the ones whose mtime/size/inode actually moved; reports are debounced per
/// client so a burst of writes collapses into one.
public final class FileWatcher: @unchecked Sendable {
    private let paths: [ClientID: URL]
    private let debounce: Duration
    private let queue = DispatchQueue(label: "co.charmtechnologies.mcpm.watch")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fds: [Int32] = []
    private var stamps: [ClientID: String] = [:]
    private var pending: [ClientID: DispatchWorkItem] = [:]
    private var continuation: AsyncStream<ClientID>.Continuation?

    public init(paths: [ClientID: URL], debounce: Duration = .milliseconds(500)) {
        self.paths = paths; self.debounce = debounce
    }

    public func start() -> AsyncStream<ClientID> {
        let (stream, cont) = AsyncStream<ClientID>.makeStream()
        continuation = cont
        for (client, url) in paths { stamps[client] = Self.stamp(url) }
        let dirs = Dictionary(grouping: paths.keys, by: { paths[$0]!.deletingLastPathComponent().path })
        for (dir, clients) in dirs {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            fds.append(fd)
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
            src.setEventHandler { [weak self] in self?.check(clients) }
            src.resume()
            sources.append(src)
            // A directory only reports entries appearing, vanishing or being renamed. An editor
            // that rewrites a file in place changes no directory entry, so watch the files too.
            for c in clients { watchFile(c) }
        }
        return stream
    }

    /// Watches one existing file directly. Re-armed by `check` whenever the file is replaced,
    /// since the old descriptor follows the old inode.
    private func watchFile(_ client: ClientID) {
        guard let url = paths[client] else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fds.append(fd)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
        src.setEventHandler { [weak self] in self?.check([client]) }
        src.resume()
        sources.append(src)
    }

    private func check(_ clients: [ClientID]) {
        for c in clients {
            let s = Self.stamp(paths[c]!)
            guard s != stamps[c] else { continue }
            let hadInode = stamps[c]
            stamps[c] = s
            if hadInode?.split(separator: "-").last != s.split(separator: "-").last { watchFile(c) }
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

    static func stamp(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sz = (a[.size] as? Int) ?? 0
        let ino = (a[.systemFileNumber] as? Int) ?? 0
        return "\(m)-\(sz)-\(ino)"
    }

    public func stop() {
        queue.sync {
            sources.forEach { $0.cancel() }
            sources.removeAll()
            fds.forEach { close($0) }
            fds.removeAll()
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
            continuation?.finish()
        }
    }
}
