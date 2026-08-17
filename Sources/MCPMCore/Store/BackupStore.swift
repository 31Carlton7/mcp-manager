import Foundation

public struct BackupStore: Sendable {
    public let root: URL
    public let keep: Int
    public init(root: URL, keep: Int = 5) { self.root = root; self.keep = keep }

    private func dir(_ c: ClientID) -> URL { root.appendingPathComponent(c.rawValue) }

    /// Copies `file` (if it exists) to `<root>/<client>/<timestamp>.<ext>` and prunes old ones.
    public func backup(_ file: URL, for client: ClientID, at date: Date) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let d = dir(client)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: date).replacingOccurrences(of: ":", with: "-")
        var dest = d.appendingPathComponent(stamp).appendingPathExtension(file.pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = d.appendingPathComponent("\(stamp)-\(suffix)").appendingPathExtension(file.pathExtension)
            suffix += 1
        }
        try FileManager.default.copyItem(at: file, to: dest)
        // copyItem carries the source's creation date over, which would make every backup of one
        // config look equally old. Stamp the copy so `list` can order by when it was taken.
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .creationDate: Date()],
                                              ofItemAtPath: dest.path)
        for old in try list(for: client).dropFirst(keep) { try FileManager.default.removeItem(at: old) }
    }

    /// Newest first. Ordered by when the backup was taken rather than by name, because a
    /// same-second collision suffix ("…00Z-2.json") sorts *before* the plain name it follows.
    public func list(for client: ClientID) throws -> [URL] {
        let d = dir(client)
        guard FileManager.default.fileExists(atPath: d.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.creationDateKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { a, b in
                let da = try? a.resourceValues(forKeys: [.creationDateKey]).creationDate
                let db = try? b.resourceValues(forKeys: [.creationDateKey]).creationDate
                if let da, let db, da != db { return da > db }
                return a.lastPathComponent > b.lastPathComponent
            }
    }
}
