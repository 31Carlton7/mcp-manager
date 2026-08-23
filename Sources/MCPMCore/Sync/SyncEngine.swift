import Foundation

public struct SyncInput: Sendable {
    public var library: Library
    /// Only readable, installed clients appear here. Missing key = leave that client alone.
    public var snapshots: [ClientID: [ExternalServer]]
    /// Clients we just wrote; their snapshot is stale by definition, so skip adoption and the
    /// "client wins on presence" rule for them this round — they're projection-only.
    public var suppressed: Set<ClientID>
    public var gatewayPort: Int
    public var now: Date
    public init(library: Library, snapshots: [ClientID: [ExternalServer]], suppressed: Set<ClientID>, gatewayPort: Int, now: Date) {
        self.library = library; self.snapshots = snapshots; self.suppressed = suppressed
        self.gatewayPort = gatewayPort; self.now = now
    }
}

public struct SyncOutput: Sendable, Equatable {
    public var library: Library
    /// Desired full server list per client that needs a write.
    public var writes: [ClientID: [ExternalServer]]
    public var adopted: [Server]
}

public enum SyncEngine {
    public static func plan(_ input: SyncInput) -> SyncOutput {
        var lib = input.library
        var adopted: [Server] = []

        // 1 + 2: import unknown servers, mark presence.
        // Suppressed clients (we just wrote them this round) skip this whole step: their
        // snapshot is stale by definition, so it must not adopt or disable anything — it's
        // projection-only in the next step.
        for (client, external) in input.snapshots.sorted(by: { $0.key < $1.key }) {
            if input.suppressed.contains(client) { continue }
            var seenIDs = Set<String>()
            for e in external.sorted(by: { $0.name < $1.name }) {
                if let idx = match(e, in: lib, port: input.gatewayPort) {
                    seenIDs.insert(lib.servers[idx].id)
                    // A library written before transport existed says nothing about it, and the
                    // client's file is the only surviving record of what the server speaks. Take
                    // it before step 3 projects the default over it, or the first sync after the
                    // upgrade would move every SSE server to HTTP. Clients that disagree are
                    // settled by whichever sorts first; the user can still change it afterwards,
                    // and an explicit `.http` here is exactly that change, so it is left alone.
                    if lib.servers[idx].kind == .remote && lib.servers[idx].transport == nil {
                        lib.servers[idx].transport = e.transport ?? .http
                    }
                    if lib.servers[idx].clients[client] != true {
                        lib.servers[idx].clients[client] = true
                    }
                } else {
                    let id = Slug.unique(Slug.make(e.name), existing: Set(lib.servers.map(\.id)))
                    let s = Server.imported(e, id: id, from: client, now: input.now)
                    lib.servers.append(s)
                    adopted.append(s)
                    seenIDs.insert(id)
                }
            }
            for i in lib.servers.indices where lib.servers[i].clients[client] == true && !seenIDs.contains(lib.servers[i].id) {
                lib.servers[i].clients[client] = false
            }
        }

        // 3 + 4: project and diff
        var writes: [ClientID: [ExternalServer]] = [:]
        for (client, current) in input.snapshots {
            let desired = lib.servers.filter { $0.isEnabled(for: client) }
                .map { $0.external(gatewayPort: input.gatewayPort) }
                .sorted { $0.name < $1.name }
            if Set(desired) != Set(current) { writes[client] = desired }
        }
        return SyncOutput(library: lib, writes: writes, adopted: adopted)
    }

    /// name → gateway-url → url → command+args
    static func match(_ e: ExternalServer, in lib: Library, port: Int) -> Int? {
        if let i = lib.servers.firstIndex(where: { $0.name == e.name }) { return i }
        if let url = e.url {
            if let id = GatewayURL.serverID(from: url, port: port),
               let i = lib.servers.firstIndex(where: { $0.id == id }) { return i }
            if let i = lib.servers.firstIndex(where: { $0.kind == .remote && $0.url == url }) { return i }
        }
        if let cmd = e.command,
           let i = lib.servers.firstIndex(where: { $0.kind == .stdio && $0.command == cmd && $0.args == e.args }) { return i }
        return nil
    }
}
