import Dispatch
import Foundation
import os
import MCPMCore
import MCPMControl

let log = Logger(subsystem: "co.charmtechnologies.mcpmd", category: "main")

/// The daemon: sync the library out to every client, watch their configs, and serve the app over
/// the control socket.
///
/// This is a `@main` type rather than top-level code in `main.swift` because top-level bindings are
/// `@MainActor`-isolated: reading one from the signal-handling queue trips a dispatch queue
/// assertion and traps. Locals of an async `main()` carry no such isolation.
@main
enum MCPMD {
    static func main() async throws {
        let paths = Paths()
        try paths.ensureRoot()

        let gatewayPort = 7337
        let coord = SyncCoordinator(store: Store(url: paths.library), adapters: AllAdapters.make(),
                                    backups: BackupStore(root: paths.backups), gatewayPort: gatewayPort)
        let handlers = Handlers(coord: coord)
        let server = ControlServer(socketPath: paths.socket.path) { req in try await handlers.handle(req) }

        // If something answers on the socket, another mcpmd is running — bail out instead of
        // stealing it. A stale socket file has no listener, so the connect fails and `start()`
        // removes the file.
        if FileManager.default.fileExists(atPath: paths.socket.path) {
            let probe = ControlClient(socketPath: paths.socket.path)
            if (try? await probe.connect()) != nil {
                await probe.close()
                log.error("another mcpmd is already listening on \(paths.socket.path, privacy: .public); exiting")
                exit(1)
            }
        }

        // A library we can't read must not keep the daemon off the air: the app reads the failure
        // off `status.lastError` and can offer to sort it out.
        do {
            try await coord.runOnce()
        } catch {
            log.error("initial sync failed: \(String(describing: error), privacy: .public)")
        }
        await coord.startWatching()
        _ = await coord.addListener { _ in
            Task { await server.broadcast(.status(await handlers.status())) }
        }
        try await server.start()
        log.info("mcpmd \(daemonVersion, privacy: .public) listening on \(paths.socket.path, privacy: .public)")

        let signalSources = trapSignals(stopping: server)

        // The work now happens on the event loops and the watcher; this task only has to stay
        // alive — and keep the signal sources alive with it, since dropping one cancels it.
        while true {
            try await Task.sleep(for: .seconds(3600))
            withExtendedLifetime(signalSources) {}
        }
    }

    /// SIGTERM and SIGINT leave through `stop()`, so the socket file goes away with the process
    /// that owns it. This lives outside `main()` on purpose: a handler closure formed inside that
    /// main-actor function inherits its isolation, and dispatch running it off the main queue then
    /// trips a queue assertion and traps.
    private static func trapSignals(stopping server: ControlServer) -> [DispatchSourceSignal] {
        let queue = DispatchQueue(label: "co.charmtechnologies.mcpmd.signals")
        return [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                Task {
                    try? await server.stop()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
    }
}
