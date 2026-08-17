import Foundation

public enum AdapterError: Error, Equatable {
    case parse(String)
}

public protocol ClientAdapter: Sendable {
    var id: ClientID { get }
    var displayName: String { get }
    var configPath: URL { get }
    func isInstalled() -> Bool
    /// `nil` data = file does not exist.
    func parse(_ data: Data?) throws -> [ExternalServer]
    /// Must preserve every byte/key not under this client's MCP section.
    func render(_ servers: [ExternalServer], over data: Data?) throws -> Data
}

public extension ClientAdapter {
    func readData() -> Data? { try? Data(contentsOf: configPath) }
}
