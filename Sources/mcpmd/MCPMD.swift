import Dispatch
import Foundation
import os
import MCPMCore
import MCPMControl
import MCPMDaemon
import MCPMGateway

let log = Logger(subsystem: "co.charmtechnologies.mcpmd", category: "main")

/// The daemon: sync the library out to every client, watch their configs, and serve the app over
/// the control socket.
///
/// This is a `@main` type rather than top-level code in `main.swift` because top-level bindings are
/// `@MainActor`-isolated: reading one from the signal-handling queue trips a dispatch queue
/// assertion and traps. Locals of an async `main()` carry no such isolation.
@main
enum MCPMD {
    static func main() async {
        do {
            try await run()
        } catch {
            // Nothing is listening yet when startup fails, so a trap would leave the user with a
            // crash report where a log line belongs.
            log.error("mcpmd failed to start: \(String(describing: error), privacy: .public)")
            exit(1)
        }
    }

    private static func run() async throws {
        // A client that hangs up mid-response would otherwise kill the daemon: the control server
        // and the gateway both write to sockets whose peer can vanish at any moment.
        signal(SIGPIPE, SIG_IGN)

        let paths = Paths()
        try paths.ensureRoot()

        // A settings file we can't parse must not keep the daemon off the air; the defaults are
        // as good a starting point as any, and `settings.set` will rewrite the file when the user
        // fixes it from the app.
        let settingsStore = SettingsStore(url: paths.settings)
        var settings = Settings()
        do {
            settings = try settingsStore.load()
        } catch {
            log.error("settings.json is unreadable, using defaults: \(String(describing: error), privacy: .public)")
        }

        let envPort = environmentGatewayPort()
        let gatewayPort = envPort ?? settings.gatewayPort
        let coord = SyncCoordinator(store: Store(url: paths.library), adapters: AllAdapters.make(),
                                    backups: BackupStore(root: paths.backups, keep: settings.backupRetention),
                                    gatewayPort: gatewayPort)
        let settingsService = SettingsService(store: settingsStore, initial: settings, runningPort: gatewayPort,
                                              portOverriddenByEnvironment: envPort != nil,
                                              applyRetention: { keep in await coord.setBackupRetention(keep) })

        // If something answers on the socket, another mcpmd is running — bail out instead of
        // stealing it. This comes before the gateway binds, so a second daemon does not report a
        // port conflict it caused itself. A stale socket file has no listener, so the connect
        // fails and `start()` removes the file.
        //
        // Exit 0, not 1: the LaunchAgent's KeepAlive only restarts on a failure, and losing this
        // race is an ordinary outcome rather than a failure. A non-zero exit would have launchd
        // respawn us into the same conflict for as long as the other daemon lives.
        if FileManager.default.fileExists(atPath: paths.socket.path) {
            let probe = ControlClient(socketPath: paths.socket.path)
            if (try? await probe.connect()) != nil {
                await probe.close()
                log.notice("another mcpmd is listening on \(paths.socket.path, privacy: .public); exiting cleanly")
                exit(0)
            }
        }

        // Every change tickles the stream; one drainer turns those into pushes. Coalescing to the
        // newest tick keeps a burst of syncs from queueing up a burst of identical statuses, and
        // the single consumer means an older status can never land after a newer one.
        let (ticks, tick) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        let auth = AuthManager(store: makeTokenStore(root: paths.root),
                               oauth: OAuthClient(http: URLSessionHTTPClient()),
                               redirectURI: GatewayConfig(port: gatewayPort).redirectURI())
        let gateway = Gateway(config: GatewayConfig(port: gatewayPort), auth: auth,
                              servers: LibraryServers(coord: coord, changed: { _ in tick.yield() }))

        // Before the first sync: that pass writes gateway URLs into client configs, and a client
        // that reads one the moment it lands should find something listening behind it.
        var boundPort: Int?
        var gatewayError: String?
        do {
            try await gateway.start()
            boundPort = await gateway.boundPort
            log.info("gateway listening on 127.0.0.1:\(boundPort ?? 0, privacy: .public)")
        } catch {
            // The config hub is still worth running without it — only authenticated servers break.
            gatewayError = "gateway did not start: \(error)"
            log.error("\(gatewayError ?? "", privacy: .public)")
        }

        let handlers = Handlers(coord: coord, auth: auth, gatewayPort: boundPort, gatewayError: gatewayError,
                                settings: settingsService)
        let server = ControlServer(socketPath: paths.socket.path) { req in try await handlers.handle(req) }

        // Bind before syncing anything: a failure to bind then leaves no trace behind, and an app
        // that connects during the first pass sees an empty library rather than no daemon.
        try await server.start()
        log.info("mcpmd \(daemonVersion, privacy: .public) listening on \(paths.socket.path, privacy: .public)")

        Task {
            for await _ in ticks {
                await server.broadcast(.status(await handlers.status()))
            }
        }
        _ = await coord.addListener { _ in tick.yield() }
        // A sign-in finishing in the browser changes no file, so nothing else would push it.
        Task {
            for await _ in auth.stateChanged { tick.yield() }
        }

        // A library we can't read must not keep the daemon off the air: the app reads the failure
        // off `status.lastError` and can offer to sort it out.
        do {
            try await coord.runOnce()
        } catch {
            log.error("initial sync failed: \(String(describing: error), privacy: .public)")
        }
        await coord.startWatching()

        let signalSources = trapSignals(stopping: server, gateway: gateway)

        // The work now happens on the event loops and the watcher; this task only has to stay
        // alive — and keep the signal sources alive with it, since dropping one cancels it.
        while true {
            try await Task.sleep(for: .seconds(3600))
            withExtendedLifetime(signalSources) {}
        }
    }

    /// `MCPM_GATEWAY_PORT` exists for tests and for a machine where the configured port is spoken
    /// for; it outranks `settings.json`. A value that is not a usable TCP port is a typo, and
    /// binding 0 would hand out an ephemeral port that no client config points at — so an
    /// unusable value is reported and ignored, falling through to the file.
    private static func environmentGatewayPort() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["MCPM_GATEWAY_PORT"] else { return nil }
        guard let port = Int(raw), Settings.portRange.contains(port) else {
            log.error("MCPM_GATEWAY_PORT=\(raw, privacy: .public) is not a port; ignoring it")
            return nil
        }
        return port
    }

    /// The Keychain by default. An unsigned development build gets a new code identity on every
    /// rebuild, so macOS prompts for access to items the previous build wrote; `MCPM_TOKEN_STORE=file`
    /// selects a 0600 JSON file under `~/.mcpm` instead.
    private static func makeTokenStore(root: URL) -> any TokenStore {
        guard ProcessInfo.processInfo.environment["MCPM_TOKEN_STORE"] == "file" else {
            return KeychainTokenStore(service: "co.charmtechnologies.mcpm")
        }
        log.info("using the file token store")
        return FileTokenStore(url: root.appendingPathComponent("tokens.json"))
    }

    /// SIGTERM and SIGINT leave through `stop()`, so the socket file goes away with the process
    /// that owns it. This lives outside `main()` on purpose: a handler closure formed inside that
    /// main-actor function inherits its isolation, and dispatch running it off the main queue then
    /// trips a queue assertion and traps.
    private static func trapSignals(stopping server: ControlServer, gateway: Gateway) -> [DispatchSourceSignal] {
        let queue = DispatchQueue(label: "co.charmtechnologies.mcpmd.signals")
        return [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                Task {
                    try? await server.stop()
                    // Gives a client parked on a proxied SSE stream its two seconds to finish,
                    // rather than having the connection die with the process.
                    await gateway.stop()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
    }
}
