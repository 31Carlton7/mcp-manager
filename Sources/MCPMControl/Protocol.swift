import Foundation
import MCPMCore

public let controlAPIVersion = 1

// MARK: - Commands

public struct SetClientParams: Codable, Equatable, Sendable {
    public var id: String
    public var client: ClientID
    public var enabled: Bool
    public init(id: String, client: ClientID, enabled: Bool) {
        self.id = id; self.client = client; self.enabled = enabled
    }
}

public struct SetAllParams: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public init(id: String, enabled: Bool) { self.id = id; self.enabled = enabled }
}

public struct IDParams: Codable, Equatable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct HelloParams: Codable, Equatable, Sendable {
    public var appVersion: String
    public init(appVersion: String) { self.appVersion = appVersion }
}

public struct ClientParams: Codable, Equatable, Sendable {
    public var client: ClientID
    public init(client: ClientID) { self.client = client }
}

public struct AddServerParams: Codable, Equatable, Sendable {
    public var name: String
    public var kind: ServerKind
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var auth: AuthKind
    public var clients: [ClientID: Bool]
    public init(name: String, kind: ServerKind, command: String? = nil, args: [String] = [], env: [String: String] = [:],
                url: String? = nil, auth: AuthKind = .none, clients: [ClientID: Bool] = [:]) {
        self.name = name; self.kind = kind; self.command = command; self.args = args; self.env = env
        self.url = url; self.auth = auth; self.clients = clients
    }
}

public struct UpdateServerParams: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public var auth: AuthKind?
    public init(id: String, name: String? = nil, command: String? = nil, args: [String]? = nil,
                env: [String: String]? = nil, url: String? = nil, auth: AuthKind? = nil) {
        self.id = id; self.name = name; self.command = command; self.args = args
        self.env = env; self.url = url; self.auth = auth
    }
}

public enum ControlCommand: Equatable, Sendable {
    case hello(HelloParams)
    case status
    case subscribe
    case listServers
    case addServer(AddServerParams)
    case updateServer(UpdateServerParams)
    case removeServer(IDParams)
    case setClient(SetClientParams)
    case setAll(SetAllParams)
    case listClients
    case reimport(ClientParams)

    public var method: String {
        switch self {
        case .hello: "hello"
        case .status: "status"
        case .subscribe: "subscribe"
        case .listServers: "servers.list"
        case .addServer: "servers.add"
        case .updateServer: "servers.update"
        case .removeServer: "servers.remove"
        case .setClient: "servers.setClient"
        case .setAll: "servers.setAll"
        case .listClients: "clients.list"
        case .reimport: "clients.reimport"
        }
    }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var command: ControlCommand
    public init(id: Int, command: ControlCommand) { self.id = id; self.command = command }

    enum CodingKeys: String, CodingKey { case id, method, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        let method = try c.decode(String.self, forKey: .method)
        switch method {
        case "hello": command = .hello(try c.decode(HelloParams.self, forKey: .params))
        case "status": command = .status
        case "subscribe": command = .subscribe
        case "servers.list": command = .listServers
        case "servers.add": command = .addServer(try c.decode(AddServerParams.self, forKey: .params))
        case "servers.update": command = .updateServer(try c.decode(UpdateServerParams.self, forKey: .params))
        case "servers.remove": command = .removeServer(try c.decode(IDParams.self, forKey: .params))
        case "servers.setClient": command = .setClient(try c.decode(SetClientParams.self, forKey: .params))
        case "servers.setAll": command = .setAll(try c.decode(SetAllParams.self, forKey: .params))
        case "clients.list": command = .listClients
        case "clients.reimport": command = .reimport(try c.decode(ClientParams.self, forKey: .params))
        default:
            throw DecodingError.dataCorruptedError(forKey: .method, in: c, debugDescription: "unknown method \(method)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(command.method, forKey: .method)
        switch command {
        case .hello(let p): try c.encode(p, forKey: .params)
        case .addServer(let p): try c.encode(p, forKey: .params)
        case .updateServer(let p): try c.encode(p, forKey: .params)
        case .removeServer(let p): try c.encode(p, forKey: .params)
        case .setClient(let p): try c.encode(p, forKey: .params)
        case .setAll(let p): try c.encode(p, forKey: .params)
        case .reimport(let p): try c.encode(p, forKey: .params)
        case .status, .subscribe, .listServers, .listClients: break
        }
    }
}

// MARK: - Status

public struct ServerStatus: Codable, Equatable, Sendable, Identifiable {
    public var server: Server
    /// "ok" | "needsAuth" | "expiring" | "connected"  (auth states arrive in Plan 2)
    public var state: String
    public var id: String { server.id }
    public init(server: Server, state: String) { self.server = server; self.state = state }
}

public struct ClientStatus: Codable, Equatable, Sendable, Identifiable {
    public var id: ClientID
    public var displayName: String
    public var installed: Bool
    public var configPath: String
    public var healthy: Bool
    /// Whether the daemon currently has a file watcher armed on this client's config.
    public var watched: Bool
    public var error: String?
    public var lastSync: Date?
    public init(id: ClientID, displayName: String, installed: Bool, configPath: String,
                healthy: Bool, watched: Bool, error: String?, lastSync: Date?) {
        self.id = id; self.displayName = displayName; self.installed = installed; self.configPath = configPath
        self.healthy = healthy; self.watched = watched; self.error = error; self.lastSync = lastSync
    }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var daemonVersion: String
    public var apiVersion: Int
    public var servers: [ServerStatus]
    public var clients: [ClientStatus]
    /// Last error from a sync pass, or nil if the last pass succeeded.
    public var lastError: String?
    public init(daemonVersion: String, apiVersion: Int, servers: [ServerStatus], clients: [ClientStatus],
                lastError: String? = nil) {
        self.daemonVersion = daemonVersion; self.apiVersion = apiVersion
        self.servers = servers; self.clients = clients; self.lastError = lastError
    }
}

// MARK: - Responses / events

public enum ControlResult: Codable, Equatable, Sendable {
    case ack
    case hello(daemonVersion: String, apiVersion: Int)
    case status(DaemonStatus)
    case servers([Server])
    case clients([ClientStatus])
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var id: Int
    public var ok: Bool
    public var result: ControlResult?
    public var error: String?
    public init(id: Int, result: ControlResult) { self.id = id; self.ok = true; self.result = result; self.error = nil }
    public init(id: Int, error: String) { self.id = id; self.ok = false; self.result = nil; self.error = error }
}

public enum ControlEvent: Codable, Equatable, Sendable {
    case status(DaemonStatus)

    enum CodingKeys: String, CodingKey { case event, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .event) {
        case "status": self = .status(try c.decode(DaemonStatus.self, forKey: .data))
        case let e: throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "unknown event \(e)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let s): try c.encode("status", forKey: .event); try c.encode(s, forKey: .data)
        }
    }
}

/// A line arriving from the daemon is either a response (has "id") or an event (has "event").
public enum ControlInbound: Sendable {
    case response(ControlResponse)
    case event(ControlEvent)

    public static func decode(_ data: Data) throws -> ControlInbound {
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], obj["event"] != nil {
            return .event(try JSONDecoder.mcpm.decode(ControlEvent.self, from: data))
        }
        return .response(try JSONDecoder.mcpm.decode(ControlResponse.self, from: data))
    }
}
