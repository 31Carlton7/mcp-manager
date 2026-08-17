import Foundation

public enum AtomicFile {
    /// Writes to `<url>.tmp` then renames over `url`. Sets POSIX mode when given.
    public static func write(_ data: Data, to url: URL, mode: Int? = nil) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
