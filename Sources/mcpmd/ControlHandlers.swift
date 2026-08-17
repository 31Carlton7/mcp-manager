import Foundation
import MCPMCore
import MCPMControl

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
        return DaemonStatus(daemonVersion: daemonVersion, apiVersion: controlAPIVersion,
                            servers: snap.library.servers.map { ServerStatus(server: $0, state: "ok") },
                            clients: clients, lastError: snap.lastError)
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
                                          env: p.env, url: p.url, auth: p.auth, clients: p.clients,
                                          source: "manual", createdAt: .init()))
            }
            return .ack
        case .updateServer(let p):
            try await coord.mutate { lib in
                guard let i = lib.servers.firstIndex(where: { $0.id == p.id }) else { throw HandlerError.notFound(p.id) }
                if let v = p.name { lib.servers[i].name = v }
                if let v = p.command { lib.servers[i].command = v }
                if let v = p.args { lib.servers[i].args = v }
                if let v = p.env { lib.servers[i].env = v }
                if let v = p.url { lib.servers[i].url = v }
                if let v = p.auth { lib.servers[i].auth = v }
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
        case .reimport(let p):
            // The suppression window exists to stop our own writes bouncing back at us; a
            // re-import is the user asking for exactly that file to be read again.
            await coord.clearSuppression(for: p.client)
            try await coord.runOnce()
            return .ack
        }
    }

    /// A server the clients can't act on is worse than no server: it lands in every config file
    /// they own before anyone notices it was never going to start.
    private func validate(_ p: AddServerParams) throws {
        guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HandlerError.invalid("name is required")
        }
        switch p.kind {
        case .stdio:
            guard !(p.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HandlerError.invalid("a stdio server needs a command")
            }
        case .remote:
            guard !(p.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HandlerError.invalid("a remote server needs a url")
            }
        }
    }
}
