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
    /// The header credential is write-only: the daemon keeps the value in the Keychain and never
    /// hands it back, so these fields start empty on every selection rather than pretending to
    /// show what is stored.
    @State private var headerName = "Authorization"
    @State private var headerValue = ""

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
        }
    }

    // MARK: auth

    /// Only remote servers have anything to say here: a stdio server's credentials live in its
    /// environment, there is no gateway hop to hang a token off, and the daemon rejects the
    /// combination outright.
    @ViewBuilder private func authSection(_ status: ServerStatus) -> some View {
        if status.server.kind == .remote {
            VStack(alignment: .leading, spacing: Space.s) {
                sectionLabel("Auth")
                stateLine(status)
                Picker("Auth", selection: Binding(
                    get: { status.server.auth },
                    set: { daemon.updateAuth(status.server.id, $0) })) {
                        Text("None").tag(AuthKind.none)
                        Text("OAuth").tag(AuthKind.oauth)
                        Text("Header").tag(AuthKind.header)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                switch status.server.auth {
                case .none: EmptyView()
                case .oauth: oauthControls(status)
                case .header: headerControls(status)
                }
                gatewayCaption(status)
            }
        }
    }

    private func stateLine(_ status: ServerStatus) -> some View {
        let state = status.authStatus
        return HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
            Text(state.label)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
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
        .font(Typography.body)
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
                    .font(Typography.body)
                    .disabled(headerName.isEmpty || headerValue.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11, design: .monospaced))
    }

    /// Says where the clients are actually being pointed, since with auth on they no longer talk to
    /// the server's own URL — and says so loudly when there is nothing listening there.
    @ViewBuilder private func gatewayCaption(_ status: ServerStatus) -> some View {
        if status.server.auth != .none {
            if let port = daemon.gatewayPort {
                Text("Clients will be pointed at the local gateway (localhost:\(String(port))).")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Gateway not running — auth unavailable")
                    .font(Typography.caption)
                    .foregroundStyle(.red)
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
            Text(status.server.auth == .none
                 ? "Written into every client's config. A credential belongs in Auth instead."
                 : "Not written to clients while auth is on — the gateway adds its own.")
                .font(Typography.caption)
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
        .font(Typography.body)
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

    /// The last test for this server, if it has been tested since the app started. It stays until
    /// the next test replaces it — a result is about a moment, and saying which moment is the
    /// timing in it.
    @ViewBuilder private func testResult(_ status: ServerStatus) -> some View {
        if let result = daemon.testResults[status.server.id] {
            Text(result.ok ? summary(result) : failure(result))
                .font(Typography.caption)
                .foregroundStyle(result.ok ? Color.green : Color.red)
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

    // MARK: editing

    /// Fields are seeded from the server once per selection, not on every status push: reloading
    /// mid-edit would wipe what the user is typing when an unrelated sync lands.
    private func loadFields() {
        argsText = status?.server.args.joined(separator: " ") ?? ""
        envRows = (status?.server.env ?? [:]).sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) }
        headerName = "Authorization"
        headerValue = ""
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
