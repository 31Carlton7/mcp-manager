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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        for old in try list(for: client).dropFirst(keep) { try FileManager.default.removeItem(at: old) }
    }

    /// Newest first.
    public func list(for client: ClientID) throws -> [URL] {
        let d = dir(client)
        guard FileManager.default.fileExists(atPath: d.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
