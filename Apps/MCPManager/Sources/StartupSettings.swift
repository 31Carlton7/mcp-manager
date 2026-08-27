import Foundation
import Observation
import ServiceManagement

/// Login-item state for the two things that can start on their own: the app, and the background
/// service behind it.
///
/// `SMAppService` has no observation of its own — status changes when the user flips a switch in
/// System Settings, with nothing to notify us — so the statuses are cached here and re-read by
/// `refresh()` whenever a surface that shows them appears.
@MainActor @Observable
final class StartupSettings {
    /// The name of the plist inside `Contents/Library/LaunchAgents`, which is also how launchd
    /// names the job once it is registered.
    static let agentPlistName = "co.charmtechnologies.mcpmd.plist"
    static let agentLabel = "co.charmtechnologies.mcpmd"

    private(set) var appStatus: SMAppService.Status
    private(set) var daemonStatus: SMAppService.Status
    private(set) var lastError: String?
    /// Separate from `lastError` so a restart failure can be reported next to the button that
    /// caused it rather than under the login-item switches.
    private(set) var serviceError: String?

    private let app: SMAppService
    private let agent: SMAppService
    /// The automatic rebind gets one attempt per launch: a rebind that didn't help would fail the
    /// same way a second time, and re-registering a login item is not something to retry in a loop.
    private var reboundThisLaunch = false

    init() {
        let app = SMAppService.mainApp
        let agent = SMAppService.agent(plistName: Self.agentPlistName)
        self.app = app
        self.agent = agent
        appStatus = app.status
        daemonStatus = agent.status
    }

    /// `.enabled` is the only status that actually launches something. `.requiresApproval` means
    /// the record exists but the user has it switched off in Login Items, which we can't override —
    /// so the toggle reads as off and the UI points at System Settings.
    var appAtLogin: Bool {
        get { appStatus == .enabled }
        set { set(newValue, on: app) { self.appStatus = $0 } }
    }

    var daemonAtLogin: Bool {
        get { daemonStatus == .enabled }
        set { set(newValue, on: agent) { self.daemonStatus = $0 } }
    }

    /// The only way to notice a change made in System Settings.
    func refresh() {
        appStatus = app.status
        daemonStatus = agent.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether there is a registered job to restart. A daemon someone started by hand is not one:
    /// launchd doesn't know about it, so it can't be kicked.
    var canRestartDaemon: Bool { daemonStatus == .enabled }

    /// Bounces the daemon so it picks up a new binary from the bundle.
    ///
    /// Not `unregister()` + `register()`: that rewrites the login-item record, and a record the
    /// user has ever declined comes back as `.requiresApproval` rather than running. `kickstart -k`
    /// only restarts the job, which is what "restart" means here.
    func restartDaemon() async {
        serviceError = nil
        guard canRestartDaemon else {
            serviceError = "The background service isn't registered with launchd — enable it above first."
            return
        }
        do {
            serviceError = try await Self.launchctl(["kickstart", "-k", "gui/\(getuid())/\(Self.agentLabel)"])
        } catch {
            serviceError = String(describing: error)
        }
        refresh()
    }

    /// Re-registers the agent if it looks stale, once per launch.
    ///
    /// launchd records the daemon's code requirement when the login item is registered. A rebuilt
    /// app is signed ad-hoc with a fresh identity, so the recorded requirement no longer matches
    /// and the spawn is refused — while `status` still reads `.enabled`, because the record is
    /// perfectly valid, just pointing at a binary launchd won't run. Re-registering rewrites it.
    ///
    /// Only for `.enabled`: re-registering a record the user has switched off in Login Items
    /// leaves it switched off, and would spend the one attempt on a state a rebind can't fix.
    func rebindDaemonIfStale() async {
        guard !reboundThisLaunch, daemonStatus == .enabled else { return }
        await repairDaemonRegistration()
    }

    /// The same rebind, without the once-per-launch guard, for the user asking for it by hand.
    func repairDaemonRegistration() async {
        serviceError = nil
        guard daemonStatus == .enabled else {
            serviceError = "The background service isn't registered with launchd — enable it above first."
            return
        }
        reboundThisLaunch = true
        // A job launchd has already given up on ("spawn failed", stale code requirement after a
        // rebuild) is not cleared by `unregister()` alone; boot it out of the domain first so the
        // fresh `register()` starts from nothing. Best effort: it fails harmlessly when the job
        // isn't loaded.
        _ = try? await Self.launchctl(["bootout", "gui/\(getuid())/\(Self.agentLabel)"])
        try? await agent.unregister()
        do {
            try agent.register()
        } catch {
            serviceError = Self.describe(error, registering: true)
        }
        refresh()
        // Re-registering asks macOS for the login item afresh, and a user who has ever declined
        // this one gets the record back switched off rather than running.
        if daemonStatus == .requiresApproval {
            serviceError = "Re-registered, but the login item needs approving in System Settings → Login Items."
        }
    }

    private func set(_ enabled: Bool, on service: SMAppService,
                     store: (SMAppService.Status) -> Void) {
        lastError = nil
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            lastError = Self.describe(error, registering: enabled)
        }
        store(service.status)
    }

    private static func describe(_ error: any Error, registering: Bool) -> String {
        let verb = registering ? "start at login" : "stop starting at login"
        return "Couldn't \(verb): \((error as NSError).localizedDescription)"
    }

    /// Returns nil on success, or launchctl's complaint. Run off the main actor: it spawns a
    /// process and waits for it.
    private static func launchctl(_ arguments: [String]) async throws -> String? {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let err = Pipe()
            process.standardError = err
            // A Pipe nobody reads fills and blocks the child; launchctl's stdout is of no use here.
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "launchctl \(arguments.joined(separator: " ")) failed (\(process.terminationStatus))"
                : detail
        }.value
    }
}
