import SwiftUI
import MCPMCore
import MCPMControl

/// Adding a server is one paste. Whatever the user has on the clipboard — the URL from a docs page,
/// the `npx …` line from a README, or the whole `{"mcpServers": …}` block — is parsed live and the
/// rest of the form fills itself in.
struct AddServerSheet: View {
    /// A catalog entry the sheet opens on. Written into the paste well rather than into the fields,
    /// so a catalog pick and a README paste take the same path through the form and the URL is
    /// checked either way.
    var prefill: CatalogEntry?

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
    /// One line to start, growing with the content up to a point past which it scrolls instead.
    @State private var pasteHeight: CGFloat = Self.pasteMinHeight
    /// What the daemon found when it asked the pasted URL what it is. Nil while there is no remote
    /// URL to ask about, and while the answer for a new one is still coming.
    @State private var inspection: URLInspection?
    @State private var checking = false
    /// Why the check itself couldn't run — a malformed URL, or the service being unreachable. Not
    /// a verdict on the server, so it says so and blocks nothing.
    @State private var inspectionError: String?
    /// Once the user picks an auth kind, an inspection stops overwriting it. Reset by a new URL,
    /// whose reading is about a different server.
    @State private var authEdited = false
    /// Set while the add is in flight, so a second Return can't add the same server twice.
    @State private var adding = false
    @State private var addError: String?
    /// A server that was just added needing a sign-in, keeping the sheet open to offer it.
    @State private var added: AddedServer?

    private struct AddedServer: Identifiable {
        let id: String
        let name: String
    }

    /// The advanced fields only make sense for a single server; a JSON block with several is taken
    /// as-is.
    private var single: ExternalServer? { parsed.servers.count == 1 ? parsed.servers[0] : nil }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHeaderName: String { headerName.trimmingCharacters(in: .whitespaces) }

    /// The URL the inspection is about, and the key its task is keyed on.
    private var remoteURL: String? {
        guard let single, single.kind == .remote, let url = single.url, !url.isEmpty else { return nil }
        return url
    }

    /// The daemon asked and the URL answered as something other than an MCP endpoint. The daemon
    /// would refuse the add anyway; saying so here saves the round trip and offers the way out.
    private var notAnEndpoint: Bool { inspection?.parsedVerdict == .notMCP }

    /// A settled answer about this exact URL. The daemon inspects again on its way in unless told
    /// not to, and that second probe is a network round trip the add sits on top of — so when the
    /// answer is already in hand it is sent along instead of asked for twice.
    private func settledInspection(for server: ExternalServer) -> URLInspection? {
        guard server.kind == .remote, !checking, remoteURL == server.url,
              let inspection, inspection.parsedVerdict == .mcpEndpoint
        else { return nil }
        return inspection
    }

    private var canAdd: Bool {
        guard !parsed.servers.isEmpty, !adding, !checking, !notAnEndpoint else { return false }
        return single == nil || !trimmedName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Add MCP server").font(.system(size: 15, weight: .semibold))

            // Everything above the buttons goes inert once the add is in flight or done: the
            // fields describe a server that either exists already or is being created from them.
            // Inert, not hidden — a control that has stopped taking input still says what it holds.
            Group {
                // The well and what was read out of it are one object, so they sit at the tight
                // spacing rather than at the block gutter.
                VStack(alignment: .leading, spacing: Space.xs) {
                    pasteField
                    summaryLine
                    inspectionLine
                }

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
                        .monospacedDigit()
                }

                LabeledContent("Enable in") { clientChips }

                if single != nil {
                    DisclosureGroup(isExpanded: $advanced) {
                        advancedFields
                            .padding(.top, Space.s)
                            // The observed indent for a nested option group.
                            .padding(.leading, 19)
                    } label: {
                        Text("Advanced")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(adding || added != nil)
            .opacity(adding || added != nil ? 0.35 : 1)

            buttons
        }
        .padding(Space.l)
        .frame(width: 460)
        .onAppear {
            clients = Set(daemon.installedClients.map(\.id))
            applyPrefill()
        }
        // A half-typed URL briefly parses as something else, so the form settles a beat after
        // typing stops.
        .task(id: paste) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reparse()
        }
        // Keyed on the URL rather than on the paste: retyping around it asks the same question,
        // and a URL that changes cancels the check that was running for the old one.
        .task(id: remoteURL) { await inspect() }
        .animation(.snappy(duration: 0.2), value: parsed.servers.count)
        .animation(.snappy(duration: 0.2), value: checking)
        .animation(.snappy(duration: 0.2), value: inspection)
        .animation(.snappy(duration: 0.2), value: added?.id)
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
            .controlWell()
            .overlay(alignment: .topLeading) {
                if paste.isEmpty {
                    Text("Paste a URL, a command, or the JSON snippet from a README…")
                        .font(pasteFont)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.s + 5)
                        .padding(.vertical, Space.s)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Server to add")
    }

    /// `TextEditor` will not report the height its content needs, so the same string in the same
    /// font is laid out behind it, hidden, and only ever contributes that height.
    private var pasteMeasure: some View {
        Text(paste.isEmpty ? " " : paste)
            .font(pasteFont)
            // TextEditor insets its own text by ~5 pt a side; matching that keeps the wrapping the
            // same in both, which is the whole point of the measurement. The placeholder above
            // matches it too.
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                pasteHeight = min(max(Self.pasteMinHeight, height + 8), Self.pasteMaxHeight)
            }
    }

    /// The parser's own words about what it found. Blank still takes up its line, so the fields
    /// below don't jump the first time something is typed.
    private var summaryLine: some View {
        Text(parsed.summary.isEmpty ? " " : parsed.summary)
            .font(Typography.rowCaption)
            .foregroundStyle(failedToParse ? AnyShapeStyle(Semantic.red) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var failedToParse: Bool {
        parsed.summary.hasPrefix("Couldn't") || parsed.summary.hasPrefix("No servers")
    }

    // MARK: inspection

    /// What the URL itself says, as opposed to what the paste said about it. Absent rather than
    /// blank for a local server, which has nothing to check.
    @ViewBuilder private var inspectionLine: some View {
        if checking {
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Checking…").font(Typography.rowCaption).foregroundStyle(.secondary)
            }
        } else if let error = inspectionError {
            statusLine("Couldn't check this URL (\(error))", symbol: "questionmark.circle", tint: .secondary)
        } else if let inspection {
            verdict(inspection)
        }
    }

    @ViewBuilder private func verdict(_ i: URLInspection) -> some View {
        switch i.parsedVerdict {
        case .mcpEndpoint:
            statusLine("MCP endpoint · \(authSentence(i))", symbol: "checkmark.circle", tint: Semantic.green)
        case .notMCP:
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                statusLine(notMCPSentence(i), symbol: "exclamationmark.triangle", tint: Semantic.red)
                if let suggestion = i.suggestion {
                    Button("Use it") { paste = suggestion }
                        .buttonStyle(.pressable)
                        .font(Typography.listValue)
                }
            }
        case .unreachable:
            statusLine("Unreachable (\(i.detail))", symbol: "bolt.horizontal", tint: Semantic.orange)
        case nil:
            // A verdict this app is too old to know about. Its sentence is still readable, and
            // nothing is blocked on a word we can't interpret.
            statusLine(i.detail, symbol: "questionmark.circle", tint: .secondary)
        }
    }

    private func authSentence(_ i: URLInspection) -> String {
        guard i.authRequired else { return "no sign-in needed" }
        switch i.authKind {
        case .oauth: return "needs sign-in (OAuth)"
        case .header: return "needs an API key header"
        case .none: return "no sign-in needed"
        }
    }

    private func notMCPSentence(_ i: URLInspection) -> String {
        let opening = "Not an MCP endpoint (\(i.detail))."
        guard let suggestion = i.suggestion else { return opening }
        return "\(opening) Did you mean \(suggestion)?"
    }

    private func statusLine(_ text: String, symbol: String, tint: some ShapeStyle) -> some View {
        Label {
            Text(text)
                .font(Typography.rowCaption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10))
        }
        .foregroundStyle(tint)
    }

    /// Asks the daemon what the pasted URL is, a beat after it stops changing. `.task(id:)` kills
    /// the check for a URL nobody is looking at any more, and its answer is dropped rather than
    /// shown against the URL that replaced it.
    private func inspect() async {
        inspection = nil
        inspectionError = nil
        // A different URL is a different server, so an auth kind chosen for the last one no longer
        // stands in the way of what this one reports — except a catalog entry's own kind, which is
        // curated knowledge about this very URL rather than a leftover from another one.
        authEdited = prefill.map { $0.auth != .none && $0.url == remoteURL } ?? false
        guard let url = remoteURL else { checking = false; return }
        checking = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let result = try await daemon.inspect(url)
            guard !Task.isCancelled else { return }
            inspection = result
            // Editable, not imposed: the picker moves to what the endpoint asked for, and the user
            // can still overrule it — a server behind a header the probe cannot see, say.
            if !authEdited, result.parsedVerdict == .mcpEndpoint {
                auth = result.authRequired ? result.authKind : .none
            }
        } catch {
            guard !Task.isCancelled else { return }
            inspectionError = DaemonClient.reason(error)
        }
        checking = false
    }

    private func preview(_ server: ExternalServer) -> some View {
        let shown = previewServer(server)
        return HStack(spacing: Space.s) {
            ServerIcon(server: shown, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.name)
                    .font(Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shown.subline)
                    .font(Typography.rowCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// A throwaway `Server` so the preview can reuse `ServerIcon` and `subline`; never saved.
    private func previewServer(_ e: ExternalServer) -> Server {
        Server(id: "preview", name: trimmedName.isEmpty ? e.name : trimmedName, kind: e.kind,
               command: e.command, args: e.args, env: e.env, url: e.url, headers: e.headers,
               transport: e.transport, source: "preview", createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: clients

    private var clientChips: some View {
        HStack(spacing: Space.xs) {
            if daemon.installedClients.isEmpty {
                Text("No supported clients installed")
                    .font(Typography.rowCaption)
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
            StatusPill(text: client.displayName, tint: on ? Semantic.green : .secondary,
                       dot: on, compact: true)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .animation(.snappy(duration: 0.15), value: on)
        .accessibilityLabel("\(client.displayName), \(on ? "on" : "off")")
    }

    // MARK: advanced

    /// Mirrors the inspector: a stdio server has a command line and an environment, a remote one
    /// has headers and can be signed in to.
    @ViewBuilder private var advancedFields: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            switch single?.kind {
            case .stdio:
                argsField
                KeyValueEditor(title: "Env", noun: "environment variable",
                               placeholder: ("KEY", "value"), rows: $envRows)
            case .remote:
                KeyValueEditor(title: "Headers", noun: "header",
                               placeholder: ("Header", "value"), rows: $headerRows)
                authField
            case nil:
                EmptyView()
            }
        }
    }

    private var argsField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("Args")
            TextField("Args", text: $argsText)
                .textFieldStyle(.roundedBorder)
                .font(Typography.mono)
                .labelsHidden()
        }
    }

    /// Only remote servers get this: a stdio server's credentials live in its environment, and the
    /// daemon rejects the combination outright.
    private var authField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("Auth")
            // Writing through the binding is the only signal that the *user* chose this kind; the
            // inspection writes `auth` directly, and must not read its own answer back as an edit.
            Picker("Auth", selection: Binding(get: { auth }, set: { auth = $0; authEdited = true })) {
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
        .font(Typography.mono)
    }

    @ViewBuilder private var authCaption: some View {
        switch auth {
        case .none:
            EmptyView()
        case .oauth:
            Text("Added signed out — use Sign in on the server to finish.")
                .font(Typography.rowCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .header:
            Text("Kept in the Keychain and added by the local gateway, not written to any client.")
                .font(Typography.rowCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: footer

    @ViewBuilder private var buttons: some View {
        if let error = addError {
            statusLine(error, symbol: "exclamationmark.triangle", tint: Semantic.red)
        }
        if let added {
            signInRow(added)
        } else {
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
    }

    /// A server added as OAuth exists but can't be reached yet, and the sign-in is one browser
    /// round trip away — worth asking here rather than leaving a badge to be found later.
    private func signInRow(_ added: AddedServer) -> some View {
        HStack(spacing: Space.s) {
            Text("Added \(added.name). Sign in now?")
                .font(Typography.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.m)
            Button("Later") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Sign in") {
                daemon.startAuth(added.id)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .transition(.opacity)
    }

    // MARK: parsing and submission

    /// Advanced fields are derived state: a fresh parse re-seeds them, because they describe the
    /// server that was just pasted rather than anything the user has committed to.
    private func reparse() {
        parsed = SmartPasteParser.parse(paste)
        // Auth is only ever offered for a single remote server: stdio has nowhere to put gateway
        // auth, and a batch paste has no per-server form, so neither may inherit a picker the user
        // set against something else.
        if single == nil || single?.kind == .stdio { auth = .none }
        guard let single else { return }
        if !nameEdited { name = single.name }
        argsText = single.args.joined(separator: " ")
        envRows = .init(single.env)
        headerRows = .init(single.headers)
    }

    /// Fills the form from a catalog entry: the paste well gets the URL, or the command line, or
    /// — when the entry names environment the command line has nowhere to put — the JSON the
    /// parser also reads, so the placeholders arrive visible and editable.
    private func applyPrefill() {
        guard let prefill, paste.isEmpty else { return }
        paste = pasteText(for: prefill)
        name = prefill.name
        nameEdited = true
        reparse()
        // After the reparse, which clears auth for anything that can't have it.
        auth = prefill.auth
    }

    private func pasteText(for entry: CatalogEntry) -> String {
        if entry.kind == .remote { return entry.url ?? "" }
        let line = ([entry.command].compactMap { $0 } + entry.args).joined(separator: " ")
        guard !entry.env.isEmpty else { return line }
        let object: [String: Any] = ["command": entry.command ?? "", "args": entry.args, "env": entry.env]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return line }
        return json
    }

    /// Awaited rather than fired off, because the daemon inspects the URL again on its way in and
    /// can still refuse — and because a server added needing a sign-in has one more thing to say.
    private func add() {
        let enabled = Dictionary(uniqueKeysWithValues: clients.map { ($0, true) })
        let requests = parsed.servers.map { params(for: $0, clients: enabled) }
        adding = true
        addError = nil
        Task {
            defer { adding = false }
            var signIn: AddedServer?
            for request in requests {
                do {
                    let id = try await daemon.addAwaiting(request)
                    // What the daemon stored, not what was asked for: it inspects the URL itself
                    // and can land on an auth kind the form didn't send.
                    if let added = daemon.servers.first(where: { $0.id == id })?.server,
                       added.auth == .oauth {
                        signIn = AddedServer(id: added.id, name: added.name)
                    }
                } catch {
                    addError = DaemonClient.reason(error)
                    return
                }
            }
            if let signIn { added = signIn } else { dismiss() }
        }
    }

    /// The single-server case sends what is on screen; a multi-server paste sends what was parsed,
    /// since there is no per-server form to read.
    private func params(for server: ExternalServer, clients: [ClientID: Bool]) -> AddServerParams {
        guard single != nil else {
            return AddServerParams(name: server.name, kind: server.kind, command: server.command,
                                   args: server.args, env: server.env, url: server.url,
                                   headers: server.headers, transport: server.transport,
                                   auth: .none, clients: clients)
        }
        let kind = server.kind == .remote ? auth : .none
        // The credential travels with the add: the daemon mints the id, so it is the only one that
        // can name the server the credential belongs to.
        let credential = kind == .header && !trimmedHeaderName.isEmpty && !headerValue.isEmpty
        let settled = settledInspection(for: server)
        return AddServerParams(name: trimmedName, kind: server.kind, command: server.command,
                               args: server.kind == .stdio ? SmartPasteParser.shellSplit(argsText) : [],
                               env: server.kind == .stdio ? envRows.dictionary : [:],
                               url: server.url,
                               headers: server.kind == .remote ? headerRows.dictionary : [:],
                               // What the endpoint answered to beats what the paste guessed: an
                               // SSE server behind a URL that doesn't say so is exactly the case
                               // the check exists for.
                               transport: settled?.transport ?? server.transport ?? prefill?.transport,
                               auth: kind, clients: clients,
                               headerName: credential ? trimmedHeaderName : nil,
                               headerValue: credential ? headerValue : nil,
                               autoDetectAuth: settled == nil)
    }
}
