import SwiftUI
import MCPMCore
import MCPMControl

// Still the plain form from Plan 1 — Task 5 replaces it with the smart-paste sheet.
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
