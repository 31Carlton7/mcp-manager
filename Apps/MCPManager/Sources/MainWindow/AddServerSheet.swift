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
    @State private var auth: AuthKind = .none
    /// The credential for header auth. It never goes into `servers.add` — that would put it in the
    /// library file and from there into every client's config — so it is sent separately, and only
    /// once the server exists.
    @State private var headerName = "Authorization"
    @State private var headerValue = ""
    /// The paste well's current height: one line to start, growing with the content up to a point
    /// past which it scrolls instead.
    @State private var pasteHeight: CGFloat = Self.pasteMinHeight

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
                    // Emptying the field is a request to go back to the parsed name.
                    TextField("Server name", text: Binding(
                        get: { name },
                        set: {
                            name = $0
                            nameEdited = !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }))
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
        // Parsing a JSON block on every keystroke is wasted work, and a half-typed URL briefly
        // parses as something else — so the form settles a beat after typing stops.
        .task(id: paste) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reparse()
        }
        .animation(.snappy(duration: 0.2), value: parsed.servers.count)
    }

    // MARK: paste

    private static let pasteMinHeight: CGFloat = 52
    private static let pasteMaxHeight: CGFloat = 140

    private var pasteFont: Font { .system(size: 12, design: .monospaced) }

    private var pasteField: some View {
        TextEditor(text: $paste)
            .font(pasteFont)
            .scrollContentBackground(.hidden)
            .frame(height: pasteHeight)
            .background(alignment: .topLeading) { pasteMeasure }
            .animation(.snappy(duration: 0.18), value: pasteHeight)
            .padding(Space.s)
            .cardSurface(cornerRadius: 10)
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

    /// The same string in the same font behind the editor, laid out at the editor's width, is the
    /// cheapest honest answer to "how tall does this need to be" — `TextEditor` won't say. It is
    /// hidden, so it only ever contributes its height.
    private var pasteMeasure: some View {
        Text(paste.isEmpty ? " " : paste)
            .font(pasteFont)
            // TextEditor insets its own text by ~5 pt a side; matching that keeps the wrapping the
            // same in both, which is the whole point of the measurement.
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                pasteHeight = min(max(Self.pasteMinHeight, height + 8), Self.pasteMaxHeight)
            }
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
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .animation(.snappy(duration: 0.15), value: on)
        .accessibilityLabel("\(client.displayName), \(on ? "on" : "off")")
    }

    // MARK: advanced

    /// Mirrors the inspector: a stdio server has a command line and an environment, a remote one has
    /// headers and can be signed in to.
    @ViewBuilder private var advancedFields: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            switch single?.kind {
            case .stdio:
                argsField
                rows("Env", placeholder: ("KEY", "value"), rows: $envRows)
            case .remote:
                rows("Headers", placeholder: ("Header", "value"), rows: $headerRows)
                authField
            case nil:
                EmptyView()
            }
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
                .buttonStyle(.pressable)
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
                    .buttonStyle(.pressable)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(row.key.isEmpty ? "empty" : row.key) entry")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    /// Only remote servers get this: a stdio server's credentials live in its environment, and the
    /// daemon rejects the combination outright.
    private var authField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Auth").font(Typography.caption).foregroundStyle(.secondary)
            Picker("Auth", selection: $auth) {
                Text("None").tag(AuthKind.none)
                Text("OAuth").tag(AuthKind.oauth)
                Text("Header").tag(AuthKind.header)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            if auth == .header {
                TextField("Header", text: $headerName)
                SecureField("value", text: $headerValue)
            }
            authCaption
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11, design: .monospaced))
    }

    @ViewBuilder private var authCaption: some View {
        switch auth {
        case .none:
            EmptyView()
        case .oauth:
            Text("Added signed out — use Sign in on the server to finish.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .header:
            Text("Kept in the Keychain and added by the local gateway, not written to any client.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: footer

    private var buttons: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
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
        // A pasted command line is a stdio server, and stdio has nowhere to put gateway auth — so a
        // picker the user set before pasting doesn't survive into a server the daemon would reject.
        if single.kind == .stdio { auth = .none }
        if !nameEdited { name = single.name }
        argsText = single.args.joined(separator: " ")
        envRows = single.env.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
        headerRows = single.headers.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
    }

    private func add() {
        let enabled = Dictionary(uniqueKeysWithValues: clients.map { ($0, true) })
        // The id the daemon is about to mint, by its own rule: a slug of the name, made unique
        // against the library we can see. Worked out before the add so the credential that follows
        // it names the right server; the commands are queued in order, so it arrives after.
        let newID = Slug.unique(Slug.make(trimmedName), existing: Set(daemon.servers.map(\.id)))
        for server in parsed.servers {
            daemon.add(params(for: server, clients: enabled))
        }
        if single != nil, auth == .header, !headerName.isEmpty, !headerValue.isEmpty {
            daemon.setHeader(newID, name: headerName.trimmingCharacters(in: .whitespaces), value: headerValue)
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
                               auth: server.kind == .remote ? auth : .none, clients: clients)
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
