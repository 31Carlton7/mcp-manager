import SwiftUI
import MCPMCore
import MCPMControl

/// Adding a server is one paste. Whatever the user has on the clipboard — the URL from a docs page,
/// the `npx …` line from a README, or the whole `{"mcpServers": …}` block — is parsed live and the
/// rest of the form fills itself in. The fields that almost nobody touches live behind Advanced.
struct AddServerSheet: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(\.dismiss) private var dismiss

    @State private var paste = ""
    @State private var parsed = SmartPasteParser.Result(servers: [], summary: "")
    @State private var name = ""
    /// Once the user types a name of their own, later parses stop overwriting it.
    @State private var nameEdited = false
    @State private var clients: Set<ClientID> = []
    @State private var advanced = false
    @State private var argsText = ""
    @State private var envRows: [KeyValueRow] = []
    @State private var headerRows: [KeyValueRow] = []

    /// Identity that survives editing: keying rows by their key would renumber the list mid-word.
    private struct KeyValueRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    /// The advanced fields only make sense for a single server; a JSON block with several is taken
    /// as-is.
    private var single: ExternalServer? { parsed.servers.count == 1 ? parsed.servers[0] : nil }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        guard !parsed.servers.isEmpty else { return false }
        return single == nil || !trimmedName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Add MCP server").font(.system(size: 15, weight: .semibold))

            pasteField
            summaryLine

            Hairline()

            if let single {
                preview(single)
                LabeledContent("Name") {
                    // Writing through the binding is the only signal that the *user* renamed the
                    // server; `onChange` would also fire when a fresh parse fills the field in.
                    TextField("Server name", text: Binding(get: { name },
                                                           set: { name = $0; nameEdited = true }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            } else if parsed.servers.count > 1 {
                Text("\(parsed.servers.count) servers will be added")
                    .font(Typography.body)
            }

            LabeledContent("Enable in") { clientChips }

            if single != nil {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    advancedFields
                        .padding(.top, Space.s)
                }
                .font(Typography.body)
            }

            buttons
        }
        .padding(Space.l)
        .frame(width: 460)
        .onAppear { clients = Set(daemon.installedClients.map(\.id)) }
        .onChange(of: paste) { reparse() }
        .animation(.snappy(duration: 0.2), value: parsed.servers.count)
    }

    // MARK: paste

    private var pasteField: some View {
        TextEditor(text: $paste)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 52, maxHeight: 140)
            .padding(Space.s)
            .glassCard(cornerRadius: 10)
            .overlay(alignment: .topLeading) {
                if paste.isEmpty {
                    // TextEditor insets its own text by ~5 pt, so the placeholder matches that
                    // rather than the container padding alone.
                    Text("Paste a URL, a command, or the JSON snippet from a README…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.s + 5)
                        .padding(.vertical, Space.s)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Server to add")
    }

    /// The parser's own words about what it found. A blank line still takes up room, so the fields
    /// below don't jump the first time something is typed.
    private var summaryLine: some View {
        Text(parsed.summary.isEmpty ? " " : parsed.summary)
            .font(Typography.caption)
            .foregroundStyle(failedToParse ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var failedToParse: Bool {
        parsed.summary.hasPrefix("Couldn't") || parsed.summary.hasPrefix("No servers")
    }

    private func preview(_ server: ExternalServer) -> some View {
        let shown = previewServer(server)
        return HStack(spacing: Space.s) {
            ServerIcon(server: shown, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shown.subline)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// A throwaway `Server` so the preview can reuse `ServerIcon` and `subline`; it is never saved.
    private func previewServer(_ e: ExternalServer) -> Server {
        Server(id: "preview", name: trimmedName.isEmpty ? e.name : trimmedName, kind: e.kind,
               command: e.command, args: e.args, env: e.env, url: e.url, headers: e.headers,
               source: "preview", createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: clients

    private var clientChips: some View {
        HStack(spacing: Space.xs) {
            if daemon.installedClients.isEmpty {
                Text("No supported clients installed")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(daemon.installedClients) { client in
                chip(client)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ client: ClientStatus) -> some View {
        let on = clients.contains(client.id)
        return Button {
            if on { clients.remove(client.id) } else { clients.insert(client.id) }
        } label: {
            Text(client.displayName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(on ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(on ? Color.green.opacity(0.18) : Color.primary.opacity(0.06), in: .capsule)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: on)
        .accessibilityLabel("\(client.displayName), \(on ? "on" : "off")")
    }

    // MARK: advanced

    /// Mirrors the inspector: a stdio server has a command line and an environment, a remote one has
    /// headers. Auth is listed so its absence is explained rather than merely missing.
    @ViewBuilder private var advancedFields: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            switch single?.kind {
            case .stdio:
                argsField
                rows("Env", placeholder: ("KEY", "value"), rows: $envRows)
            case .remote:
                rows("Headers", placeholder: ("Header", "value"), rows: $headerRows)
            case nil:
                EmptyView()
            }
            authField
        }
    }

    private var argsField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Args").font(Typography.caption).foregroundStyle(.secondary)
            TextField("Args", text: $argsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .labelsHidden()
        }
    }

    private func rows(_ title: String, placeholder: (String, String),
                      rows: Binding<[KeyValueRow]>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).font(Typography.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { rows.wrappedValue.append(KeyValueRow(key: "", value: "")) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Add \(title) entry")
            }
            ForEach(rows) { $row in
                HStack(spacing: Space.xs) {
                    TextField(placeholder.0, text: $row.key)
                    TextField(placeholder.1, text: $row.value)
                    Button {
                        rows.wrappedValue.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(row.key.isEmpty ? "empty" : row.key)")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private var authField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Picker("Auth", selection: .constant(AuthKind.none)) {
                Text("None").tag(AuthKind.none)
                Text("OAuth").tag(AuthKind.oauth)
            }
            .disabled(true)
            .font(Typography.body)
            Text("Available in a later version")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: footer

    private var buttons: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
        }
    }

    // MARK: parsing and submission

    /// Advanced fields are derived state: a fresh parse re-seeds them, because they describe the
    /// server that was just pasted rather than anything the user has committed to.
    private func reparse() {
        parsed = SmartPasteParser.parse(paste)
        guard let single else { return }
        if !nameEdited { name = single.name }
        argsText = single.args.joined(separator: " ")
        envRows = single.env.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
        headerRows = single.headers.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
    }

    private func add() {
        let enabled = Dictionary(uniqueKeysWithValues: clients.map { ($0, true) })
        for server in parsed.servers {
            daemon.add(params(for: server, clients: enabled))
        }
        dismiss()
    }

    /// The single-server case sends what is on screen; a multi-server paste sends what was parsed,
    /// since there is no per-server form to read.
    private func params(for server: ExternalServer, clients: [ClientID: Bool]) -> AddServerParams {
        guard single != nil else {
            return AddServerParams(name: server.name, kind: server.kind, command: server.command,
                                   args: server.args, env: server.env, url: server.url,
                                   headers: server.headers, auth: .none, clients: clients)
        }
        return AddServerParams(name: trimmedName, kind: server.kind, command: server.command,
                               args: server.kind == .stdio ? SmartPasteParser.shellSplit(argsText) : [],
                               env: server.kind == .stdio ? dictionary(envRows) : [:],
                               url: server.url,
                               headers: server.kind == .remote ? dictionary(headerRows) : [:],
                               auth: .none, clients: clients)
    }

    /// Rows with a blank key are the half-typed ones; they are dropped rather than sent as "".
    private func dictionary(_ rows: [KeyValueRow]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = row.value }
        }
        return out
    }
}
