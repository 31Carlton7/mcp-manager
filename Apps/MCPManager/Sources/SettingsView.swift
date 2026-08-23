import SwiftUI
import ServiceManagement
import MCPMCore

/// The Settings scene: what starts on its own, and the state of the thing that does the work.
/// Everything here is either a login-item switch or a read-only fact about the daemon — the
/// server library is the main window's job.
struct SettingsView: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(StartupSettings.self) private var startup

    @State private var restarting = false
    /// The field's own value. Seeded from the daemon's saved settings and left alone after that,
    /// so a status arriving mid-edit can't retype what the user is halfway through.
    @State private var port = Settings.defaultGatewayPort

    var body: some View {
        @Bindable var startup = startup
        Form {
            Section("Startup") {
                Toggle("Launch MCP Manager at login", isOn: $startup.appAtLogin)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Toggle("Run background service at login", isOn: $startup.daemonAtLogin)
                    Text("Keeps your MCP servers connected after a restart — recommended.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    if startup.daemonStatus == .requiresApproval {
                        approval
                    }
                }

                if let error = startup.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Background service") {
                LabeledContent("Status") {
                    HStack(spacing: Space.xs) {
                        Circle()
                            .fill(daemon.isConnected ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(daemon.isConnected ? "Running" : "Unreachable")
                    }
                }
                gatewayPort
                HStack {
                    Spacer()
                    Button("Restart background service") { restart() }
                        .disabled(restarting || !startup.canRestartDaemon)
                        .help(startup.canRestartDaemon
                              ? "Reloads the daemon from the app bundle"
                              : "Only a service registered with launchd can be restarted")
                }
                if let error = startup.serviceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typography.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // Login Items can be changed in System Settings while this window sits open, and
        // `SMAppService` never says so.
        .onAppear { startup.refresh(); daemon.start() }
        // Keyed on the connection, so a Settings window opened before the daemon is reachable
        // still gets its values once it is — and again after a restart, which is exactly when the
        // saved port has just become the running one.
        .task(id: daemon.isConnected) {
            guard daemon.isConnected else { return }
            await daemon.loadSettings()
        }
        // Only when the daemon's own value moves — the first load, or a save coming back — so
        // typing is never overwritten by a routine status push.
        .onChange(of: daemon.settings?.gatewayPort) { _, saved in
            if let saved { port = saved }
        }
    }

    /// The port the gateway *will* use, which is not always the one it is on: a change is written
    /// to `settings.json` and picked up on the next start, because the port is already baked into
    /// every client config the daemon has written.
    @ViewBuilder private var gatewayPort: some View {
        LabeledContent("Gateway port") {
            HStack(spacing: Space.s) {
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .disabled(daemon.settings == nil || daemon.savingSettings)
                Button("Apply") { applyPort() }
                    .disabled(!canApplyPort)
            }
        }

        VStack(alignment: .leading, spacing: Space.xs) {
            Text(portLabel)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            if let error = daemon.settingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
            }
            if daemon.settingsPendingRestart {
                Label("Saved — restart the background service to apply the new port.",
                      systemImage: "arrow.clockwise")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var canApplyPort: Bool {
        guard let saved = daemon.settings?.gatewayPort, !daemon.savingSettings else { return false }
        return port != saved && Settings.portRange.contains(port)
    }

    private func applyPort() {
        Task { await daemon.saveSettings(gatewayPort: port) }
    }

    /// The one status the toggle can't fix: the record is installed, the user has it switched off,
    /// and only they can switch it back on.
    private var approval: some View {
        HStack(spacing: Space.s) {
            Text("Approve in System Settings → Login Items")
                .font(Typography.caption)
                .foregroundStyle(.orange)
            Button("Open Login Items") { startup.openLoginItemsSettings() }
                .buttonStyle(.link)
                .font(Typography.caption)
        }
    }

    private var portLabel: String {
        guard let bound = daemon.gatewayPort else { return "The gateway is not running." }
        return "Listening on 127.0.0.1:\(bound)."
    }

    private func restart() {
        restarting = true
        Task {
            await startup.restartDaemon()
            restarting = false
        }
    }
}
