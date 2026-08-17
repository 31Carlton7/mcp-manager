public enum ServerKind: String, Codable, Sendable, Hashable { case stdio, remote }

/// Exactly what a client config file can express. Adapters parse to / render from this.
public struct ExternalServer: Codable, Hashable, Sendable {
    public var name: String
    public var kind: ServerKind
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]

    public init(name: String, kind: ServerKind, command: String? = nil, args: [String] = [],
                env: [String: String] = [:], url: String? = nil, headers: [String: String] = [:]) {
        self.name = name; self.kind = kind; self.command = command; self.args = args
        self.env = env; self.url = url; self.headers = headers
    }
}
