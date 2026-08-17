import AppKit
import SwiftUI
import MCPMCore
import MCPMControl

struct MenuBarView: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if let s = daemon.status {
                if s.servers.isEmpty {
                    Text("No servers yet").foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(s.servers) { row($0, installed: s.clients.filter(\.installed).map(\.id)) }
                }
            }
            Divider()
            Button("Add server…") { openWindow(id: "main") }
            Button("Open MCP Manager…") { openWindow(id: "main") }
            Button("Quit MCP Manager") { NSApp.terminate(nil) }
                .help("The background service keeps running")
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 300)
        .onAppear { daemon.start() }
    }

    private var header: some View {
        HStack {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            if let s = daemon.status {
                Text("\(s.servers.count) servers · \(s.clients.filter(\.installed).count) clients")
            } else if case .disconnected(let why) = daemon.connection {
                Text("Background service unreachable").foregroundStyle(.red).help(why)
            } else {
                Text("Connecting…").foregroundStyle(.secondary)
            }
            Spacer()
        }.font(.headline)
    }

    private var dotColor: Color {
        guard let s = daemon.status else { return .red }
        if s.clients.contains(where: { $0.installed && !$0.healthy }) { return .red }
        if s.servers.contains(where: { $0.state == "needsAuth" }) { return .yellow }
        return .green
    }

    private func row(_ st: ServerStatus, installed: [ClientID]) -> some View {
        let anyOn = installed.contains { st.server.isEnabled(for: $0) }
        return HStack {
            Circle().fill(anyOn ? Color.green : Color.gray).frame(width: 6, height: 6)
            Text(st.server.name)
            Spacer()
            Toggle("", isOn: Binding(get: { anyOn }, set: { daemon.setAll(st.server.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}
