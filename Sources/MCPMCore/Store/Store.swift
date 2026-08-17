import Foundation

public enum StoreError: Error, Equatable { case corrupt(String) }

public struct Store: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Library {
        guard let data = try? Data(contentsOf: url) else { return Library() }
        do { return try JSONDecoder.mcpm.decode(Library.self, from: data) }
        catch { throw StoreError.corrupt(String(describing: error)) }
    }

    public func save(_ library: Library) throws {
        try AtomicFile.write(try JSONEncoder.mcpm.encode(library), to: url, mode: 0o600)
    }
}
