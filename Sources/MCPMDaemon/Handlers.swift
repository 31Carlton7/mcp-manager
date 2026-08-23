import Foundation
import MCPMCore
import MCPMControl
import MCPMGateway

public let daemonVersion = MCPMVersion.current

public enum HandlerError: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound(let id): "no server with id \"\(id)\""
        case .invalid(let why): why
        }
    }
}

/// Turns control requests into coordinator calls. One instance serves every connection.
public struct Handlers: Sendable {
    let coord: SyncCoordinator
    let auth: AuthManager
    /// The port the gateway bound, or nil if it never started. Authenticated servers are
    /// unreachable in that case, and `servers.test` says so rather than dialling a dead port.
    let gatewayPort: Int?
    /// Why the gateway is missing. Surfaced through `lastError` so the app has something to show
    /// beyond a server stuck at "needs sign-in".
    let gatewayError: String?
    let settings: SettingsService
    let probeTimeout: Duration

    public init(coord: SyncCoordinator, auth: AuthManager, gatewayPort: Int?, gatewayError: String? = nil,
                settings: SettingsService, probeTimeout: Duration = .seconds(10)) {
        self.coord = coord
        self.auth = auth
        self.gatewayPort = gatewayPort
        self.gatewayError = gatewayError
        self.settings = settings
        self.probeTimeout = probeTimeout
    }

    public func status() async -> DaemonStatus {
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
            // A server with no auth has nothing in the credential store, so a status pass over a
            // library of them never touches the actor (or, with the Keychain, the security daemon).
            let state = s.auth == .none ? AuthState.none : await auth.state(for: s.id, auth: s.auth)
            servers.append(ServerStatus(server: s, state: state.rawValue))
        }
        // A real sync or gateway failure outranks the restart note: that note is a nudge, and the
        // other two are things that are broken right now.
        let pending = await settings.pendingRestart
        return DaemonStatus(daemonVersion: daemonVersion, apiVersion: controlAPIVersion,
                            servers: servers, clients: clients,
                            lastError: snap.lastError ?? gatewayError
                                ?? (pending ? SettingsService.restartNote : nil),
                            gatewayPort: gatewayPort, settingsPendingRestart: pending,
                            importConfirmed: await settings.importConfirmed)
    }

    public func handle(_ req: ControlRequest) async throws -> ControlResult {
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
            // Before the mutate, so a malformed header doesn't leave a server behind that the
            // caller was told wasn't added.
            let credential = try headerCredential(p)
            let id = try await coord.mutate { lib in
                let id = Slug.unique(Slug.make(p.name), existing: Set(lib.servers.map(\.id)))
                lib.servers.append(Server(id: id, name: p.name, kind: p.kind, command: p.command, args: p.args,
                                          env: p.env, url: p.url, headers: p.headers, transport: p.transport,
                                          auth: p.auth, clients: p.clients,
                                          source: "manual", createdAt: .init()))
                return id
            }
            if let credential {
                try await auth.setHeader(id: id, name: credential.name, value: credential.value)
            }
            return .ack
        case .updateServer(let p):
            let previousAuth = await coord.currentLibrary().server(id: p.id)?.auth
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
                if let v = p.headers { patched.headers = v }
                if let v = p.auth { patched.auth = v }
                try validate(name: patched.name, kind: patched.kind, command: patched.command,
                             url: patched.url, auth: patched.auth)
                lib.servers[i] = patched
            }
            // Credentials belong to one auth kind: a token kept across a switch to header auth (or
            // to none) would be re-attached the moment the user switched back, long after the
            // server it was issued for may have changed.
            if let new = p.auth, let previousAuth, new != previousAuth { await auth.forget(id: p.id) }
            return .ack
        case .removeServer(let p):
            try await coord.mutate { lib in lib.servers.removeAll { $0.id == p.id } }
            // Ids are slugs of the name, so the next server called "Notion" claims this one's id.
            // A credential left behind would then be sent to whatever URL that new server has.
            await auth.forget(id: p.id)
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
            try validateHeader(name: p.name, value: p.value)
            try await auth.setHeader(id: s.id, name: p.name, value: p.value)
            return .ack
        case .getSettings:
            return .settings(await settings.settings)
        case .setSettings(let p):
            // Errors come back as the validation message rather than as a thrown actor error, so
            // the app can put "8 is not a valid port" in front of the field the user typed into.
            do {
                let saved = try await settings.apply(
                    SettingsPatch(gatewayPort: p.gatewayPort, backupRetention: p.backupRetention))
                return .settings(saved)
            } catch let e as SettingsService.ValidationError {
                throw HandlerError.invalid(e.description)
            }
        case .syncPreview:
            let (plan, snapshots) = await coord.plannedChanges()
            return .syncPreview(preview(plan, against: snapshots))
        case .confirmImport:
            // Recorded first: read-only mode is derived from this, and a daemon that lifted the
            // block without persisting the answer would ask again on the next start, after it had
            // already rewritten the files.
            try await settings.confirmImport()
            await coord.setReadOnly(false)
            try await coord.runOnce()
            return .ack
        }
    }

    /// Turns a plan into something a human can be shown before it happens: what would be taken
    /// into the library, and what each client's file would gain, lose or have rewritten.
    private func preview(_ plan: SyncOutput, against snapshots: [ClientID: [ExternalServer]]) -> SyncPreview {
        // The clients come from the planned library rather than from `adopted`, whose entries are
        // snapshots taken the moment each server was first seen: a server found in three files is
        // adopted once, by the first of them, and only the library learns about the other two.
        let adopted = plan.adopted.map { s in
            let clients = (plan.library.server(id: s.id) ?? s).clients.filter(\.value).keys.sorted()
            return ServerSummary(id: s.id, name: s.name, kind: s.kind, clients: clients)
        }
        let writes = plan.writes.map { client, desired -> ClientWrite in
            let current = Dictionary(snapshots[client, default: []].map { ($0.name, $0) },
                                     uniquingKeysWith: { a, _ in a })
            let after = Dictionary(desired.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            return ClientWrite(client: client,
                               adds: after.keys.filter { current[$0] == nil }.sorted(),
                               removes: current.keys.filter { after[$0] == nil }.sorted(),
                               // Same name, different shape: this is the entry one client is about
                               // to lose its own version of.
                               changes: after.filter { name, e in
                                   guard let was = current[name] else { return false }
                                   return was != e
                               }.keys.sorted())
        }
        return SyncPreview(adopted: adopted.sorted { $0.name < $1.name },
                           writes: writes.sorted { $0.client < $1.client })
    }

    /// The header credential carried by an add, validated here so `servers.add` either produces a
    /// server with its credential in place or produces nothing at all. A credential sent for a
    /// server that isn't on header auth is refused rather than quietly stored: it would sit in the
    /// Keychain unused until the day someone switched the auth kind.
    private func headerCredential(_ p: AddServerParams) throws -> (name: String, value: String)? {
        guard let name = p.headerName, let value = p.headerValue else {
            guard p.headerName == nil, p.headerValue == nil else {
                throw HandlerError.invalid("a header credential needs both a name and a value")
            }
            return nil
        }
        guard p.auth == .header else {
            throw HandlerError.invalid("a header credential needs auth: header")
        }
        try validateHeader(name: name, value: value)
        return (name, value)
    }

    /// A pasted header goes onto the wire verbatim. RFC 7230 says a field name is a token and a
    /// field value carries no bare CR or LF; anything else is a request-splitting attempt or a
    /// copy-paste accident, and both are better refused here than at the upstream server.
    private func validateHeader(name: String, value: String) throws {
        // RFC 7230 §3.2.6 tchar.
        let tchar = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !name.isEmpty, name.allSatisfy(tchar.contains) else {
            throw HandlerError.invalid("\"\(name)\" is not a valid header name")
        }
        // Scalars, not characters: "\r\n" is a single Swift `Character` and matches neither half.
        guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            throw HandlerError.invalid("a header value cannot contain a line break")
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
