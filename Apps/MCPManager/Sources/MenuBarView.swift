import AppKit
import SwiftUI
import MCPMCore
import MCPMControl

extension DaemonClient.Health {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .yellow
        case .error: .red
        }
    }
}

/// The status item itself. Menu bar images are template-rendered, so the tint can be ignored;
/// the badge is what reliably carries a warning or an error into the menu bar.
struct MenuBarLabel: View {
    @Environment(DaemonClient.self) private var daemon

    var body: some View {
        Image(systemName: "powerplug.fill")
            .foregroundStyle(daemon.health.color)
            .overlay(alignment: .topTrailing) {
                if daemon.health != .ok {
                    Circle().fill(daemon.health.color)
                        .frame(width: 4, height: 4)
                        .offset(x: 2, y: -1)
                }
            }
            .onAppear { daemon.start() }
    }
}

struct MenuBarView: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if let s = daemon.status {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if s.servers.isEmpty {
                            Text("No servers yet").foregroundStyle(.secondary).padding(.vertical, 4)
                        } else {
                            ForEach(s.servers) { row($0, installed: s.clients.filter(\.installed).map(\.id)) }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .disabled(!daemon.isConnected)
                .opacity(daemon.isConnected ? 1 : 0.5)
            }
            Divider()
            Button("Add server…") { open() }
            Button("Open MCP Manager…") { open() }
            Button("Quit MCP Manager") { NSApp.terminate(nil) }
                .help("The background service keeps running")
            if let err = daemon.lastError {
                Text(err).foregroundStyle(.red).font(.caption).lineLimit(3)
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 300)
        .onAppear { daemon.start() }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private var header: some View {
        HStack {
            Circle().fill(daemon.health.color).frame(width: 8, height: 8)
            if let why = daemon.disconnectReason {
                Text("Background service unreachable").foregroundStyle(.red).help(why)
            } else if !daemon.isConnected {
                Text("Connecting…").foregroundStyle(.secondary)
            } else if let s = daemon.status {
                Text("\(s.servers.count) servers · \(s.clients.filter(\.installed).count) clients")
            } else {
                Text("Connecting…").foregroundStyle(.secondary)
            }
            Spacer()
        }.font(.headline)
    }

    private func row(_ st: ServerStatus, installed: [ClientID]) -> some View {
        let anyOn = daemon.isEnabledAnywhere(st.server, installed: installed)
        return HStack {
            Circle().fill(anyOn ? Color.green : Color.gray).frame(width: 6, height: 6)
            Text(st.server.name)
            Spacer()
            Toggle(st.server.name, isOn: Binding(get: { anyOn }, set: { daemon.setAll(st.server.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}
