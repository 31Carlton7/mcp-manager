public enum ServerKind: String, Codable, Sendable, Hashable { case stdio, remote }

/// How a remote server is spoken to. Streamable HTTP is the current MCP transport and the default;
/// SSE is the older one that a good many deployed servers still only offer, and a client pointed at
/// one with the wrong transport simply fails to connect — so it has to travel with the server
/// rather than be guessed per client.
public enum Transport: String, Codable, Sendable { case http, sse }

/// Exactly what a client config file can express. Adapters parse to / render from this.
public struct ExternalServer: Codable, Hashable, Sendable {
    public var name: String
    public var kind: ServerKind
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]
    /// nil means Streamable HTTP. `.http` normalizes to nil on the way in, so the same server never
    /// has two spellings — two that did would compare unequal and make the sync write for nothing.
    public var transport: Transport?

    public init(name: String, kind: ServerKind, command: String? = nil, args: [String] = [],
                env: [String: String] = [:], url: String? = nil, headers: [String: String] = [:],
                transport: Transport? = nil) {
        self.name = name; self.kind = kind; self.command = command; self.args = args
        self.env = env; self.url = url; self.headers = headers
        self.transport = Transport.stored(transport, kind: kind)
    }

    /// `transport` arrived after the first release, so a value written without it still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  kind: try c.decode(ServerKind.self, forKey: .kind),
                  command: try c.decodeIfPresent(String.self, forKey: .command),
                  args: try c.decode([String].self, forKey: .args),
                  env: try c.decode([String: String].self, forKey: .env),
                  url: try c.decodeIfPresent(String.self, forKey: .url),
                  headers: try c.decode([String: String].self, forKey: .headers),
                  transport: try c.decodeIfPresent(Transport.self, forKey: .transport))
    }
}

extension Transport {
    /// The canonical stored form: nil for the default transport, and nil for a stdio server, which
    /// has no connection to make a choice about.
    static func stored(_ transport: Transport?, kind: ServerKind) -> Transport? {
        guard kind == .remote, transport == .sse else { return nil }
        return transport
    }

    /// The canonical form for a library server, where nil is not a spelling of the default but
    /// "never recorded". A remote server built in memory always knows its transport, so an
    /// unstated one is HTTP; only a library file written before transport existed can be nil.
    static func recorded(_ transport: Transport?, kind: ServerKind) -> Transport? {
        kind == .remote ? (transport ?? .http) : nil
    }
}
