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
    /// The last registration failure, in the user's words rather than an `OSStatus`.
    private(set) var lastError: String?

    private let app: SMAppService
    private let agent: SMAppService

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

    /// Re-reads both statuses. Cheap, and the only way to notice a change made in System Settings.
    func refresh() {
        appStatus = app.status
        daemonStatus = agent.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Bounces the daemon so it picks up a new binary from the bundle.
    ///
    /// Not `unregister()` + `register()`: that rewrites the login-item record, and a record the
    /// user has ever declined comes back as `.requiresApproval` rather than running. `kickstart -k`
    /// only restarts the job, which is what "restart" means here.
    func restartDaemon() async {
        lastError = nil
        let label = "gui/\(getuid())/\(Self.agentLabel)"
        do {
            let failure = try await Self.launchctl(["kickstart", "-k", label])
            if let failure { lastError = failure }
        } catch {
            lastError = String(describing: error)
        }
        refresh()
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
            process.standardOutput = Pipe()
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
