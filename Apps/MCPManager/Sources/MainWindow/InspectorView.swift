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
    @State private var envRows: [KeyValueRow] = []
    @State private var advanced = false
    @State private var showRemove = false
    /// The header credential is write-only: the daemon keeps the value in the Keychain and never
    /// hands it back, so these fields start empty on every selection rather than pretending to
    /// show what is stored.
    @State private var headerName = "Authorization"
    @State private var headerValue = ""
    /// What the segmented control shows. Held locally so it moves on the click rather than a round
    /// trip later, and re-synced from the daemon whenever it answers.
    @State private var authSelection: AuthKind = .none
    /// A switch that would sign the user out, waiting on them to say so.
    @State private var confirmAuth: AuthKind?

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
        // The picker is optimistic, so the daemon's answer — the change landing, or the server
        // being edited from somewhere else — is what puts it right again.
        .onChange(of: status?.server.auth) { _, new in authSelection = new ?? .none }
    }

    private func detail(_ status: ServerStatus) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header(status)
                    enabledIn(status)
                    connection(status)
                    authSection(status)
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
                    .font(Typography.rowCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func enabledIn(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("Enabled in")
            if daemon.installedClients.isEmpty {
                Text("No supported clients installed")
                    .font(Typography.rowCaption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(daemon.installedClients) { client in
                    Toggle(client.displayName, isOn: Binding(
                        get: { daemon.isEnabled(status.server, for: client.id) },
                        set: { daemon.setClient(status.server.id, client.id, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(Typography.value)
                }
            }
        }
    }

    private func connection(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("Connection")
            detailRow(status.server.kind == .remote ? "URL" : "Command") {
                Text(endpoint(status.server))
                    .font(Typography.mono)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The label column is absolute, so nothing shifts sideways as one server is swapped for
    /// another.
    private func detailRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label)
                .font(Typography.rowCaption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    // MARK: auth

    /// Only remote servers have anything to say here: a stdio server's credentials live in its
    /// environment, there is no gateway hop to hang a token off, and the daemon rejects the
    /// combination outright.
    @ViewBuilder private func authSection(_ status: ServerStatus) -> some View {
        if status.server.kind == .remote {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionLabel("Auth")
                stateLine(status)
                Picker("Auth", selection: Binding(
                    get: { authSelection },
                    set: { pick($0, for: status) })) {
                        Text("None").tag(AuthKind.none)
                        Text("OAuth").tag(AuthKind.oauth)
                        Text("Header").tag(AuthKind.header)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                Text("Switching auth kind removes stored credentials")
                    .font(Typography.rowCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch status.server.auth {
                case .none: EmptyView()
                case .oauth: oauthControls(status)
                case .header: headerControls(status)
                }
                gatewayCaption(status)
            }
            .confirmationDialog("Switch auth kind?", isPresented: confirming, presenting: confirmAuth) { kind in
                Button("Sign out and switch", role: .destructive) {
                    daemon.updateAuth(status.server.id, kind)
                }
                Button("Cancel", role: .cancel) { authSelection = status.server.auth }
            } message: { _ in
                Text("Switching auth signs you out of \(status.server.name).")
            }
        }
    }

    private var confirming: Binding<Bool> {
        Binding(get: { confirmAuth != nil }, set: { if !$0 { confirmAuth = nil } })
    }

    /// A switch away from a working sign-in throws the credential away, so it asks first. Every
    /// other switch has nothing to lose and goes straight through.
    private func pick(_ kind: AuthKind, for status: ServerStatus) {
        guard kind != status.server.auth else { return }
        authSelection = kind
        switch status.authStatus {
        case .connected, .expiring: confirmAuth = kind
        case .none, .needsAuth, .error: daemon.updateAuth(status.server.id, kind)
        }
    }

    private func stateLine(_ status: ServerStatus) -> some View {
        let state = status.authStatus
        return StatusPill(text: state.label, tint: state.color)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Auth: \(state.label)")
    }

    @ViewBuilder private func oauthControls(_ status: ServerStatus) -> some View {
        HStack(spacing: Space.xs) {
            switch status.authStatus {
            case .connected, .expiring:
                Button("Sign out") { daemon.signOut(status.server.id) }
                // Forgetting also drops the client registration, which is the fix for a server that
                // has forgotten us — rare enough that it doesn't belong next to Sign out.
                Menu {
                    Button("Forget registration") { daemon.forget(status.server.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More auth actions")
            case .none, .needsAuth, .error:
                Button("Sign in…") { daemon.startAuth(status.server.id) }
                    .disabled(daemon.gatewayPort == nil)
                    .help("Opens your browser to finish the sign-in")
            }
            Spacer(minLength: 0)
        }
        .font(Typography.field)
    }

    private func headerControls(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            TextField("Header", text: $headerName)
                .onSubmit { saveHeader(status) }
            SecureField("value", text: $headerValue)
                .onSubmit { saveHeader(status) }
            HStack {
                Spacer(minLength: 0)
                Button("Save") { saveHeader(status) }
                    .font(Typography.field)
                    .disabled(headerName.isEmpty || headerValue.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(Typography.mono)
    }

    /// Says where the clients are actually being pointed, since with auth on they no longer talk to
    /// the server's own URL — and says so loudly when there is nothing listening there.
    @ViewBuilder private func gatewayCaption(_ status: ServerStatus) -> some View {
        if status.server.auth != .none {
            if let port = daemon.gatewayPort {
                // Demo capture only; see DemoCapture.swift.
                let shown = DemoCapture.isActive ? Settings.defaultGatewayPort : port
                Text("Clients will be pointed at the local gateway (localhost:\(String(shown))).")
                    .font(Typography.rowCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Gateway not running — auth unavailable")
                    .font(Typography.rowCaption)
                    .foregroundStyle(Semantic.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveHeader(_ status: ServerStatus) {
        let name = headerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !headerValue.isEmpty else { return }
        daemon.setHeader(status.server.id, name: name, value: headerValue)
        // The value is in the Keychain now; keeping a copy on screen would only be a copy to leak.
        headerValue = ""
    }

    @ViewBuilder private func advancedSection(_ status: ServerStatus) -> some View {
        DisclosureGroup(isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: Space.m) {
                switch status.server.kind {
                case .stdio:
                    args(status)
                    KeyValueEditor(.env, rows: $envRows) { commitEnv(status) }
                case .remote:
                    headers(status)
                }
            }
            .padding(.top, Space.s)
        } label: {
            SectionLabel("Advanced")
        }
    }

    private func args(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("Args")
            TextField("Args", text: $argsText)
                .textFieldStyle(.roundedBorder)
                .font(Typography.mono)
                .labelsHidden()
                .onSubmit { commitArgs(status) }
        }
    }

    private func headers(_ status: ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("Headers")
            if status.server.headers.isEmpty {
                Text("None").font(Typography.rowCaption).foregroundStyle(.secondary)
            } else {
                ForEach(status.server.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: Space.xs) {
                        Text(key).foregroundStyle(.secondary)
                        Text(value).lineLimit(1).truncationMode(.middle)
                    }
                    .font(Typography.mono)
                }
            }
            Text(status.server.auth == .none
                 ? "Written into every client's config. A credential belongs in Auth instead."
                 : "Not written to clients while auth is on — the gateway adds its own.")
                .font(Typography.rowCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ status: ServerStatus) -> some View {
        let running = daemon.testing.contains(status.server.id)
        return VStack(alignment: .leading, spacing: Space.xs) {
            testResult(status)
            HStack {
                Button("Test") { Task { await daemon.test(status.server.id) } }
                    .disabled(running)
                if running {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Testing")
                }
                Spacer(minLength: Space.s)
                Button("Remove", role: .destructive) { showRemove = true }
            }
        }
        .font(Typography.field)
        .padding(Space.m)
        .animation(.snappy(duration: 0.2), value: running)
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

    @ViewBuilder private func testResult(_ status: ServerStatus) -> some View {
        if let result = daemon.testResults[status.server.id] {
            Text(result.ok ? summary(result) : failure(result))
                .font(Typography.listValue)
                .monospacedDigit()
                .foregroundStyle(result.ok ? Semantic.green : Semantic.red)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ r: TestResult) -> String {
        var parts: [String] = []
        let who = [r.serverName, r.serverVersion].compactMap { $0 }.joined(separator: " ")
        parts.append(who.isEmpty ? "Connected" : who)
        if let n = r.toolCount { parts.append(n == 1 ? "1 tool" : "\(n) tools") }
        parts.append("\(r.durationMs) ms")
        return parts.joined(separator: " · ")
    }

    /// The probe's own words, except for the one case where they describe the plumbing rather than
    /// what to do about it.
    private func failure(_ r: TestResult) -> String {
        guard let error = r.error, !error.isEmpty else { return "Test failed" }
        return error.contains("needs sign-in") ? "Sign in first" : error
    }

    // MARK: text

    private func endpoint(_ server: Server) -> String {
        switch server.kind {
        case .stdio: ([server.command ?? ""] + server.args).joined(separator: " ")
        case .remote: server.url ?? ""
        }
    }

    // MARK: editing

    /// Fields are seeded from the server once per selection, not on every status push: reloading
    /// mid-edit would wipe what the user is typing when an unrelated sync lands.
    private func loadFields() {
        argsText = status?.server.args.joined(separator: " ") ?? ""
        envRows = .init(status?.server.env ?? [:])
        headerName = "Authorization"
        headerValue = ""
        authSelection = status?.server.auth ?? .none
        confirmAuth = nil
    }

    private func commitArgs(_ status: ServerStatus) {
        // Shell-split rather than whitespace-split, so a quoted arg ("chrome canary") stays one arg.
        let args = SmartPasteParser.shellSplit(argsText)
        guard args != status.server.args else { return }
        daemon.update(UpdateServerParams(id: status.server.id, args: args))
    }

    private func commitEnv(_ status: ServerStatus) {
        let env = envRows.dictionary
        guard env != status.server.env else { return }
        daemon.update(UpdateServerParams(id: status.server.id, env: env))
    }
}
