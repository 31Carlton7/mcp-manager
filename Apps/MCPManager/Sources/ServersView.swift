import SwiftUI
import MCPMCore
import MCPMControl

struct ServersView: View {
    @Environment(DaemonClient.self) private var daemon
    @State private var selection: String?
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            if let s = daemon.status {
                let clients = s.clients.filter(\.installed)
                Table(s.servers, selection: $selection) {
                    TableColumn("Name") { Text($0.server.name) }
                    TableColumn("Kind") { Text($0.server.kind.rawValue).foregroundStyle(.secondary) }.width(60)
                    TableColumnForEach(clients) { c in
                        TableColumn(c.displayName) { st in
                            Toggle("", isOn: Binding(get: { st.server.isEnabled(for: c.id) },
                                                     set: { daemon.setClient(st.server.id, c.id, $0) }))
                                .labelsHidden()
                        }.width(110)
                    }
                }
                if let err = daemon.lastError {
                    Text(err).foregroundStyle(.red).font(.caption).padding(6)
                }
                unhealthyBanner(s)
            } else {
                ContentUnavailableView("Connecting to background service…", systemImage: "powerplug")
            }
        }
        .toolbar {
            Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
            Button { if let id = selection { daemon.remove(id); selection = nil } } label: { Label("Remove", systemImage: "minus") }
                .disabled(selection == nil)
        }
        .sheet(isPresented: $showAdd) { AddServerSheet().environment(daemon) }
        .onAppear { daemon.start() }
    }

    @ViewBuilder private func unhealthyBanner(_ s: DaemonStatus) -> some View {
        ForEach(s.clients.filter { $0.installed && !$0.healthy }) { c in
            Label("\(c.displayName) config could not be parsed — not syncing to it. \(c.error ?? "")",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).padding(6)
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
                }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
