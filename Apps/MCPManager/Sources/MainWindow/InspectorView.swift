import SwiftUI
import MCPMCore
import MCPMControl

/// Everything about one server that doesn't fit on its card. Edits are committed on submit rather
/// than on every keystroke, so a half-typed environment variable never reaches a client file.
struct InspectorView: View {
    let serverID: String?
    /// Called after a removal, so the grid drops its selection with the server.
    var clear: () -> Void = {}

    @Environment(DaemonClient.self) private var daemon

    @State private var argsText = ""
    @State private var envRows: [EnvRow] = []
    @State private var advanced = false
    @State private var showRemove = false

    /// Identity that survives editing: keying rows by their name would renumber the list mid-word.
    private struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    private var status: ServerStatus? {
        guard let serverID else { return nil }
        return daemon.status?.servers.first { $0.id == serverID }
    }

    var body: some View {
        Group {
            if let status {
                detail(status)
            } else {
                ContentUnavailableView("Select a server", systemImage: "square.grid.2x2")
            }
        }
        .onChange(of: serverID, initial: true) { loadFields() }
    }

    private func detail(_ status: ServerStatus) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header(status)
                    enabledIn(status)
                    connection(status)
                    advancedSection(status)
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer(status)
        }
        .disabled(!daemon.isConnected)
        .opacity(daemon.isConnected ? 1 : 0.5)
    }

    // MARK: sections

    private func header(_ status: ServerStatus) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            ServerIcon(server: status.server, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.server.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(status.server.subline)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func enabledIn(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            sectionLabel("Enabled in")
            if daemon.installedClients.isEmpty {
                Text("No supported clients installed").font(Typography.caption).foregroundStyle(.secondary)
            } else {
                ForEach(daemon.installedClients) { client in
                    Toggle(client.displayName, isOn: Binding(
                        get: { daemon.isEnabled(status.server, for: client.id) },
                        set: { daemon.setClient(status.server.id, client.id, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(Typography.body)
                }
            }
        }
    }

    private func connection(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sectionLabel("Connection")
            Text(endpoint(status.server))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(authLine(status))
                .font(Typography.caption)
                .foregroundStyle(status.state == "needsAuth" ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.secondary))
        }
    }

    @ViewBuilder private func advancedSection(_ status: ServerStatus) -> some View {
        DisclosureGroup(isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: Space.m) {
                switch status.server.kind {
                case .stdio:
                    args(status)
                    env(status)
                case .remote:
                    headers(status)
                }
            }
            .padding(.top, Space.s)
        } label: {
            sectionLabel("Advanced")
        }
    }

    private func args(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Args").font(Typography.caption).foregroundStyle(.secondary)
            TextField("Args", text: $argsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .labelsHidden()
                .onSubmit { commitArgs(status) }
        }
    }

    private func env(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Env").font(Typography.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { envRows.append(EnvRow(key: "", value: "")) } label: { Image(systemName: "plus") }
                    .buttonStyle(.pressable)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Add environment variable")
            }
            ForEach($envRows) { $row in
                HStack(spacing: Space.xs) {
                    TextField("KEY", text: $row.key)
                        .onSubmit { commitEnv(status) }
                    TextField("value", text: $row.value)
                        .onSubmit { commitEnv(status) }
                    Button {
                        envRows.removeAll { $0.id == row.id }
                        commitEnv(status)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(row.key.isEmpty ? "empty" : row.key) environment variable")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func headers(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Headers").font(Typography.caption).foregroundStyle(.secondary)
            if status.server.headers.isEmpty {
                Text("None").font(Typography.caption).foregroundStyle(.secondary)
            } else {
                ForEach(status.server.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: Space.xs) {
                        Text(key).foregroundStyle(.secondary)
                        Text(value).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            Text("Header editing arrives with the auth gateway")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ status: ServerStatus) -> some View {
        HStack {
            Button("Test") {}
                .disabled(true)
                .help("Available in a later version")
            Spacer(minLength: Space.s)
            Button("Remove", role: .destructive) { showRemove = true }
        }
        .font(Typography.body)
        .padding(Space.m)
        .confirmationDialog("Remove server?", isPresented: $showRemove) {
            Button("Remove \(status.server.name)", role: .destructive) {
                daemon.remove(status.server.id)
                clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(status.server.name) from all clients?")
        }
    }

    // MARK: text

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.label)
            .tracking(Typography.labelTracking)
            .foregroundStyle(.secondary)
    }

    private func endpoint(_ server: Server) -> String {
        switch server.kind {
        case .stdio: ([server.command ?? ""] + server.args).joined(separator: " ")
        case .remote: server.url ?? ""
        }
    }

    private func authLine(_ status: ServerStatus) -> String {
        switch status.server.auth {
        case .none: "No auth"
        case .oauth: status.state == "needsAuth" ? "OAuth · needs sign-in" : "OAuth · connected"
        case .header: "Header auth"
        }
    }

    // MARK: editing

    /// Fields are seeded from the server once per selection, not on every status push: reloading
    /// mid-edit would wipe what the user is typing when an unrelated sync lands.
    private func loadFields() {
        argsText = status?.server.args.joined(separator: " ") ?? ""
        envRows = (status?.server.env ?? [:]).sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) }
    }

    private func commitArgs(_ status: ServerStatus) {
        // Shell-split rather than whitespace-split, so a quoted arg ("chrome canary") stays one arg.
        let args = SmartPasteParser.shellSplit(argsText)
        guard args != status.server.args else { return }
        daemon.update(UpdateServerParams(id: status.server.id, args: args))
    }

    private func commitEnv(_ status: ServerStatus) {
        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = row.value }
        }
        guard env != status.server.env else { return }
        daemon.update(UpdateServerParams(id: status.server.id, env: env))
    }
}
