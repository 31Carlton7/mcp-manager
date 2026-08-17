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
    public var auth: AuthKind
    public var clients: [ClientID: Bool]
    public var source: String
    public var createdAt: Date

    public init(id: String, name: String, kind: ServerKind, command: String? = nil, args: [String] = [],
                env: [String: String] = [:], url: String? = nil, auth: AuthKind = .none,
                clients: [ClientID: Bool] = [:], source: String, createdAt: Date) {
        self.id = id; self.name = name; self.kind = kind; self.command = command; self.args = args
        self.env = env; self.url = url; self.auth = auth; self.clients = clients
        self.source = source
        // JSONEncoder.mcpm's .iso8601 strategy has whole-second resolution (no fractional
        // seconds), so normalize here to keep in-memory equality consistent with a save/load
        // round trip through Store.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    public func isEnabled(for client: ClientID) -> Bool { clients[client] ?? false }

    /// Whether requests for this server are routed through the local auth gateway.
    public var usesGateway: Bool { kind == .remote && auth != .none }

    public func external(gatewayPort: Int) -> ExternalServer {
        switch kind {
        case .stdio:
            return ExternalServer(name: name, kind: .stdio, command: command, args: args, env: env)
        case .remote:
            let u = usesGateway ? GatewayURL.make(port: gatewayPort, serverID: id) : (url ?? "")
            return ExternalServer(name: name, kind: .remote, url: u)
        }
    }

    /// Build a library server from something found in a client file.
    public static func imported(_ e: ExternalServer, id: String, from client: ClientID, now: Date) -> Server {
        Server(id: id, name: e.name, kind: e.kind, command: e.command, args: e.args, env: e.env,
               url: e.url, auth: .none, clients: [client: true], source: "imported:\(client.rawValue)",
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
    public mutating func upsert(_ s: Server) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
    }
}

extension JSONEncoder {
    public static var mcpm: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
