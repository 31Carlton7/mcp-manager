import Foundation
import MCPMCore
import MCPMControl
import MCPMGateway

let daemonVersion = "0.1.0"

enum HandlerError: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String)

    var description: String {
        switch self {
        case .notFound(let id): "no server with id \"\(id)\""
        case .invalid(let why): why
        }
    }
}

/// Turns control requests into coordinator calls. One instance serves every connection.
struct Handlers: Sendable {
    let coord: SyncCoordinator
    let auth: AuthManager
    /// The port the gateway bound, or nil if it never started. Authenticated servers are
    /// unreachable in that case, and `servers.test` says so rather than dialling a dead port.
    let gatewayPort: Int?
    /// Why the gateway is missing. Surfaced through `lastError` so the app has something to show
    /// beyond a server stuck at "needs sign-in".
    let gatewayError: String?
    let probeTimeout: Duration

    init(coord: SyncCoordinator, auth: AuthManager, gatewayPort: Int?, gatewayError: String? = nil,
         probeTimeout: Duration = .seconds(10)) {
        self.coord = coord
        self.auth = auth
        self.gatewayPort = gatewayPort
        self.gatewayError = gatewayError
        self.probeTimeout = probeTimeout
    }

    func status() async -> DaemonStatus {
        // One read: a status assembled from separate calls could show a library and a health map
        // from either side of a sync.
        let snap = await coord.snapshot()
        let clients = await coord.adapters.map { a in
            let health = snap.health[a.id]
            return ClientStatus(id: a.id, displayName: a.displayName, installed: a.isInstalled(),
                                configPath: a.configPath.path, healthy: health?.healthy ?? true,
                                watched: health?.watched ?? true, error: health?.error,
                                lastSync: health?.lastSync)
        }
        var servers: [ServerStatus] = []
        servers.reserveCapacity(snap.library.servers.count)
        for s in snap.library.servers {
            servers.append(ServerStatus(server: s, state: await auth.state(for: s.id, auth: s.auth).rawValue))
        }
        return DaemonStatus(daemonVersion: daemonVersion, apiVersion: controlAPIVersion,
                            servers: servers, clients: clients,
                            lastError: snap.lastError ?? gatewayError, gatewayPort: gatewayPort)
    }

    func handle(_ req: ControlRequest) async throws -> ControlResult {
        switch req.command {
        case .hello:
            return .hello(daemonVersion: daemonVersion, apiVersion: controlAPIVersion)
        case .status, .subscribe:
            return .status(await status())
        case .listServers:
            return .servers(await coord.currentLibrary().servers)
        case .listClients:
            return .clients(await status().clients)
        case .addServer(let p):
            try validate(p)
            try await coord.mutate { lib in
                let id = Slug.unique(Slug.make(p.name), existing: Set(lib.servers.map(\.id)))
                lib.servers.append(Server(id: id, name: p.name, kind: p.kind, command: p.command, args: p.args,
                                          env: p.env, url: p.url, headers: p.headers, auth: p.auth, clients: p.clients,
                                          source: "manual", createdAt: .init()))
            }
            return .ack
        case .updateServer(let p):
            try await coord.mutate { lib in
                guard let i = lib.servers.firstIndex(where: { $0.id == p.id }) else { throw HandlerError.notFound(p.id) }
                // Validate the patched copy before it goes into the library: a half-applied
                // patch would sync an unusable server out to every client that has it on.
                var patched = lib.servers[i]
                if let v = p.name { patched.name = v }
                if let v = p.command { patched.command = v }
                if let v = p.args { patched.args = v }
                if let v = p.env { patched.env = v }
                if let v = p.url { patched.url = v }
                if let v = p.auth { patched.auth = v }
                try validate(name: patched.name, kind: patched.kind, command: patched.command,
                             url: patched.url, auth: patched.auth)
                lib.servers[i] = patched
            }
            return .ack
        case .removeServer(let p):
            try await coord.mutate { lib in lib.servers.removeAll { $0.id == p.id } }
            return .ack
        case .setClient(let p):
            try await coord.mutate { lib in
                guard let i = lib.servers.firstIndex(where: { $0.id == p.id }) else { throw HandlerError.notFound(p.id) }
                lib.servers[i].clients[p.client] = p.enabled
            }
            return .ack
        case .setAll(let p):
            let installed = await coord.adapters.filter { $0.isInstalled() }.map(\.id)
            try await coord.mutate { lib in
                guard let i = lib.servers.firstIndex(where: { $0.id == p.id }) else { throw HandlerError.notFound(p.id) }
                for c in installed { lib.servers[i].clients[c] = p.enabled }
            }
            return .ack
        case .testServer(let p):
            return .testResult(convert(try await probe(server(p.id))))
        case .reimport(let p):
            // The suppression window exists to stop our own writes bouncing back at us; a
            // re-import is the user asking for exactly that file to be read again.
            await coord.clearSuppression(for: p.client)
            try await coord.runOnce()
            return .ack
        case .authStart(let p):
            let s = try await server(p.id)
            guard s.kind == .remote, let raw = s.url, let url = URL(string: raw) else {
                throw HandlerError.invalid("only a remote server can be signed in to")
            }
            guard s.auth == .oauth else {
                throw HandlerError.invalid("\(s.name) is not set to OAuth")
            }
            return .authorizeURL(try await auth.startAuth(id: s.id, serverURL: url).absoluteString)
        case .authSignOut(let p):
            let s = try await server(p.id)
            await auth.signOut(id: s.id)
            return .ack
        case .authForget(let p):
            let s = try await server(p.id)
            await auth.forget(id: s.id)
            return .ack
        case .authSetHeader(let p):
            let s = try await server(p.id)
            guard s.auth == .header else {
                throw HandlerError.invalid("\(s.name) is not set to header auth")
            }
            guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HandlerError.invalid("a header needs a name")
            }
            try await auth.setHeader(id: s.id, name: p.name, value: p.value)
            return .ack
        }
    }

    private func server(_ id: String) async throws -> Server {
        guard let s = await coord.currentLibrary().server(id: id) else { throw HandlerError.notFound(id) }
        return s
    }

    // MARK: - Test connection

    /// Probes a server the way its clients reach it: an authenticated remote server is dialled
    /// through the gateway, so the test exercises the same credential injection a real client gets.
    private func probe(_ s: Server) async throws -> ProbeResult {
        switch s.kind {
        case .stdio:
            guard let command = s.command, !command.isEmpty else {
                throw HandlerError.invalid("a stdio server needs a command")
            }
            return await MCPProbe.stdio(command: command, args: s.args, env: s.env, timeout: probeTimeout)
        case .remote:
            guard let raw = s.url, let url = URL(string: raw) else {
                throw HandlerError.invalid("a remote server needs a url")
            }
            guard s.usesGateway else {
                return await MCPProbe.remote(url: url, headers: s.headers, timeout: probeTimeout)
            }
            guard let port = gatewayPort else {
                return ProbeResult(ok: false, error: "gateway not running", durationMs: 0)
            }
            let gateway = URL(string: "http://127.0.0.1:\(port)/s/\(s.id)/mcp")!
            return await MCPProbe.remote(url: gateway, timeout: probeTimeout)
        }
    }

    private func convert(_ r: ProbeResult) -> TestResult {
        TestResult(ok: r.ok, serverName: r.serverName, serverVersion: r.serverVersion,
                   protocolVersion: r.protocolVersion, toolCount: r.toolCount, error: r.error,
                   durationMs: r.durationMs)
    }

    /// A server the clients can't act on is worse than no server: it lands in every config file
    /// they own before anyone notices it was never going to start.
    private func validate(_ p: AddServerParams) throws {
        try validate(name: p.name, kind: p.kind, command: p.command, url: p.url, auth: p.auth)
    }

    private func validate(name: String, kind: ServerKind, command: String?, url: String?,
                          auth: AuthKind) throws {
        func filled(_ s: String?) -> Bool {
            !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard filled(name) else { throw HandlerError.invalid("name is required") }
        switch kind {
        case .stdio:
            guard filled(command) else { throw HandlerError.invalid("a stdio server needs a command") }
            // A stdio server's credentials live in its environment; there is no gateway hop to
            // hang a token off, and accepting one would rewrite nothing and connect nowhere.
            guard auth == .none else { throw HandlerError.invalid("a stdio server cannot use gateway auth") }
        case .remote:
            guard filled(url) else { throw HandlerError.invalid("a remote server needs a url") }
        }
    }
}
