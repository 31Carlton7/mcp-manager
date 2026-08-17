import MCPMCore
import MCPMGateway

/// The gateway's view of the library. Reads go straight to the coordinator so a server edited a
/// moment ago is proxied with its new URL; `markNeedsAuth` only nudges the status pump, since the
/// state itself is derived from the credential store on every read.
public struct LibraryServers: GatewayServerSource {
    let coord: SyncCoordinator
    let changed: @Sendable (String) -> Void

    public init(coord: SyncCoordinator, changed: @escaping @Sendable (String) -> Void) {
        self.coord = coord
        self.changed = changed
    }

    public func server(id: String) async -> Server? { await coord.currentLibrary().server(id: id) }
    public func markNeedsAuth(id: String) async { changed(id) }
}
