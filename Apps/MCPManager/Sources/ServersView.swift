import SwiftUI
import MCPMCore
import MCPMControl

struct ServersView: View {
    @Environment(DaemonClient.self) private var daemon
    @State private var selection: String?
    @State private var showAdd = false
    @State private var showRemove = false

    private var selectedServer: ServerStatus? {
        daemon.status?.servers.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let s = daemon.status {
                // The last status the daemon sent is still the best guess at the truth, so it
                // stays on screen while disconnected — greyed out, since editing it can't work.
                table(s)
                    .disabled(!daemon.isConnected)
                    .opacity(daemon.isConnected ? 1 : 0.5)
                if let why = daemon.disconnectReason {
                    banner("Background service unreachable — \(why)", color: .red)
                }
                if let err = daemon.lastError {
                    Text(err).foregroundStyle(.red).font(.caption).padding(6)
                }
                // The daemon's own last failure — a sync or write that went wrong with nobody
                // watching — as opposed to the command we just sent.
                if let err = s.lastError {
                    banner("Background service: \(err)", color: .orange)
                }
                unhealthyBanner(s)
            } else if let why = daemon.disconnectReason {
                ContentUnavailableView("Background service unreachable", systemImage: "powerplug",
                                       description: Text(why))
            } else {
                ContentUnavailableView("Connecting to background service…", systemImage: "powerplug")
            }
        }
        .toolbar {
            Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
            Button { showRemove = true } label: { Label("Remove", systemImage: "minus") }
                .disabled(selectedServer == nil)
        }
        .sheet(isPresented: $showAdd) { AddServerSheet().environment(daemon) }
        .confirmationDialog("Remove server?", isPresented: $showRemove, presenting: selectedServer) { st in
            Button("Remove \(st.server.name)", role: .destructive) {
                daemon.remove(st.server.id)
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { st in
            Text("Remove \(st.server.name) from all clients?")
        }
        .onAppear { daemon.start() }
    }

    private func table(_ s: DaemonStatus) -> some View {
        let clients = s.clients.filter(\.installed)
        return Table(s.servers, selection: $selection) {
            TableColumn("Name") { Text($0.server.name) }
            TableColumn("Kind") { Text($0.server.kind.rawValue).foregroundStyle(.secondary) }.width(60)
            TableColumnForEach(clients) { c in
                TableColumn(c.displayName) { st in
                    Toggle(st.server.name,
                           isOn: Binding(get: { daemon.isEnabled(st.server, for: c.id) },
                                         set: { daemon.setClient(st.server.id, c.id, $0) }))
                        .labelsHidden()
                }.width(110)
            }
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(color).padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func unhealthyBanner(_ s: DaemonStatus) -> some View {
        ForEach(s.clients.filter { $0.installed && !$0.healthy }) { c in
            banner("\(c.displayName) config could not be parsed — not syncing to it. \(c.error ?? "")",
                   color: .orange)
        }
    }
}

struct AddServerSheet: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ServerKind = .stdio
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""

    /// Mirrors the daemon's own validation, so the button can't send something it will reject.
    private var isValid: Bool {
        func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filled(name) && (kind == .stdio ? filled(command) : filled(url))
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Kind", selection: $kind) {
                Text("stdio").tag(ServerKind.stdio)
                Text("remote").tag(ServerKind.remote)
            }
            if kind == .stdio {
                TextField("Command", text: $command)
                TextField("Args (space separated)", text: $args)
            } else {
                TextField("URL", text: $url)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let installed = daemon.status?.clients.filter(\.installed).map(\.id) ?? []
                    daemon.add(AddServerParams(name: name, kind: kind,
                                               command: kind == .stdio ? command : nil,
                                               args: kind == .stdio ? args.split(separator: " ").map(String.init) : [],
                                               url: kind == .remote ? url : nil,
                                               clients: Dictionary(uniqueKeysWithValues: installed.map { ($0, true) })))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
