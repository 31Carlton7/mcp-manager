import SwiftUI
import ServiceManagement

/// The Settings scene: what starts on its own, and the state of the thing that does the work.
/// Everything here is either a login-item switch or a read-only fact about the daemon — the
/// server library is the main window's job.
struct SettingsView: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(StartupSettings.self) private var startup

    @State private var restarting = false

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
                LabeledContent("Gateway port", value: portLabel)
                HStack {
                    Spacer()
                    Button("Restart background service") { restart() }
                        .disabled(restarting)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // Login Items can be changed in System Settings while this window sits open, and
        // `SMAppService` never says so.
        .onAppear { startup.refresh() }
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
        guard let port = daemon.gatewayPort else { return "Not running" }
        return "127.0.0.1:\(port)"
    }

    private func restart() {
        restarting = true
        Task {
            await startup.restartDaemon()
            restarting = false
        }
    }
}
