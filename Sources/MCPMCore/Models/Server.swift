import Foundation

public enum AuthKind: String, Codable, Sendable, Hashable { case none, oauth, header }

public struct Server: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ServerKind
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]
    /// The transport this remote server speaks, recorded whenever we know it — including `.http`,
    /// which is written out rather than left implicit. nil means "never recorded": a stdio server,
    /// or a library file written before transport existed. See `SyncEngine.plan`, which backfills
    /// the second case from whatever the clients say rather than assuming the default.
    public var transport: Transport?
    public var auth: AuthKind
    public var clients: [ClientID: Bool]
    public var source: String
    public var createdAt: Date

    public init(id: String, name: String, kind: ServerKind, command: String? = nil, args: [String] = [],
                env: [String: String] = [:], url: String? = nil, headers: [String: String] = [:],
                transport: Transport? = nil, auth: AuthKind = .none,
                clients: [ClientID: Bool] = [:], source: String, createdAt: Date) {
        self.id = id; self.name = name; self.kind = kind; self.command = command; self.args = args
        self.env = env; self.url = url; self.headers = headers; self.auth = auth; self.clients = clients
        self.transport = Transport.recorded(transport, kind: kind)
        self.source = source
        // JSONEncoder.mcpm's .iso8601 strategy has whole-second resolution (no fractional
        // seconds), so normalize here to keep in-memory equality consistent with a save/load
        // round trip through Store.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, command, args, env, url, headers, transport, auth, clients, source, createdAt
    }

    /// An absent `transport` stays nil rather than becoming `.http`: that is the one place the
    /// distinction between "HTTP" and "not yet known" survives, and the sync needs it to avoid
    /// rewriting an SSE server on the first run after the upgrade. `headers` predates neither, so
    /// a library file written before it existed needs the default too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ServerKind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decode([String].self, forKey: .args)
        env = try c.decode([String: String].self, forKey: .env)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        transport = kind == .remote ? try c.decodeIfPresent(Transport.self, forKey: .transport) : nil
        auth = try c.decode(AuthKind.self, forKey: .auth)
        clients = try c.decode([ClientID: Bool].self, forKey: .clients)
        source = try c.decode(String.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public func isEnabled(for client: ClientID) -> Bool { clients[client] ?? false }

    /// Whether requests for this server are routed through the local auth gateway.
    public var usesGateway: Bool { kind == .remote && auth != .none }

    public func external(gatewayPort: Int) -> ExternalServer {
        switch kind {
        case .stdio:
            return ExternalServer(name: name, kind: .stdio, command: command, args: args, env: env)
        case .remote:
            // The transport travels even through the gateway: the proxy speaks whatever the
            // upstream does, so the client on the other side still has to be told which.
            let u = usesGateway ? GatewayURL.make(port: gatewayPort, serverID: id) : (url ?? "")
            return ExternalServer(name: name, kind: .remote, url: u,
                                  headers: usesGateway ? [:] : headers, transport: transport)
        }
    }

    /// Build a library server from something found in a client file.
    public static func imported(_ e: ExternalServer, id: String, from client: ClientID, now: Date) -> Server {
        Server(id: id, name: e.name, kind: e.kind, command: e.command, args: e.args, env: e.env,
               url: e.url, headers: e.headers, transport: e.transport,
               auth: .none, clients: [client: true], source: "imported:\(client.rawValue)",
               createdAt: now)
    }
}

public struct Library: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var servers: [Server]
    public init(version: Int = Library.currentVersion, servers: [Server] = []) {
        self.version = version; self.servers = servers
    }
    public func server(id: String) -> Server? { servers.first { $0.id == id } }
}

extension JSONEncoder {
    public static var mcpm: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Single-line encoder for wire protocols, where a newline terminates a message.
    public static var mcpmWire: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
extension JSONDecoder {
    public static var mcpm: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
