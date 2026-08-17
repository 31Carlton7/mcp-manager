import Foundation

public enum AdapterError: Error, Equatable, CustomStringConvertible {
    case parse(String)

    public var description: String {
        switch self {
        case .parse(let msg): msg
        }
    }
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
    /// `nil` when the file does not exist; rethrows any other read failure.
    func readData() throws -> Data? {
        do {
            return try Data(contentsOf: configPath)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
