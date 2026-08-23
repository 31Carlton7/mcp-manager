import SwiftUI
import ServiceManagement
import MCPMCore
import MCPMControl

/// First launch, in three steps: start the background service, look at what the first import would
/// do, and say yes to it.
///
/// The second step is the reason this exists. Until it is finished the daemon runs read-only —
/// reading every client and planning, writing nothing — because two clients that describe the same
/// server differently mean one of their config files is about to be rewritten, and that is not a
/// thing to do to someone on first launch without showing them first.
struct OnboardingSheet: View {
    private enum Step: Int, CaseIterable {
        case service, importing, done

        var title: String {
            switch self {
            case .service: "Background service"
            case .importing: "Import your servers"
            case .done: "You're all set"
            }
        }
    }

    /// The preview's three states. A failure is kept rather than collapsed into "nothing found":
    /// an empty list and an unanswered daemon must not offer the same button.
    private enum Preview {
        case loading
        case loaded(SyncPreview)
        case failed(String)
    }

    @Environment(DaemonClient.self) private var daemon
    @Environment(StartupSettings.self) private var startup
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .service
    @State private var preview: Preview = .loading
    @State private var showChanges = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            // One container per step rather than a branch around the whole sheet: the header and
            // footer are the same views throughout, so only the middle animates.
            body(for: step)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Space.xl)
            Hairline()
            footer
        }
        .frame(width: 540, height: 480)
        .animation(.snappy(duration: 0.22), value: step)
        .onAppear { startup.refresh() }
        // Keyed on the connection: a sheet opened before the daemon is reachable still gets its
        // preview once it is, rather than sitting on a spinner forever.
        .task(id: daemon.isConnected) { await load() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: Space.m)
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { dot in
                    Circle()
                        .fill(dot == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.m)
    }

    // MARK: steps

    @ViewBuilder private func body(for step: Step) -> some View {
        switch step {
        case .service: serviceStep
        case .importing: importStep
        case .done: doneStep
        }
    }

    // MARK: step 1 — background service

    @ViewBuilder private var serviceStep: some View {
        @Bindable var startup = startup
        VStack(alignment: .leading, spacing: Space.l) {
            Text("MCP Manager keeps one library of servers and writes it out to every client you use. "
                 + "The work happens in a small background service.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Toggle("Start it at login", isOn: $startup.daemonAtLogin)
                    Text("Recommended")
                        .font(Typography.label)
                        .tracking(Typography.labelTracking)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.14), in: .capsule)
                    Spacer(minLength: 0)
                }
                Text("Without this, your servers stop syncing the next time you restart the Mac.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                // Registering again cannot clear an approval the user withheld — only they can,
                // in System Settings — so this asks for that rather than offering a button that
                // would no-op.
                if startup.daemonStatus == .requiresApproval {
                    HStack(spacing: Space.s) {
                        Text("Approve MCP Manager in System Settings → Login Items")
                            .font(Typography.caption)
                            .foregroundStyle(.orange)
                        Button("Open Login Items") { startup.openLoginItemsSettings() }
                            .buttonStyle(.link)
                            .font(Typography.caption)
                    }
                }
                if let error = startup.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typography.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(Space.m)
            .cardSurface(cornerRadius: 12)

            Text("You can change this later in Settings.")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: step 2 — import

    @ViewBuilder private var importStep: some View {
        switch preview {
        case .loading:
            VStack(spacing: Space.m) {
                ProgressView()
                Text("Reading your clients…").font(Typography.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            ContentUnavailableView("Couldn't read your clients", systemImage: "exclamationmark.triangle",
                                   description: Text(why))
        case .loaded(let p):
            VStack(alignment: .leading, spacing: Space.m) {
                Text(foundLabel(p))
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ForEach(groups(p), id: \.client) { group in
                            clientGroup(group)
                        }
                    }
                    .padding(.bottom, Space.s)
                }
                changes(p)
            }
        }
    }

    /// Grouped by the client the servers were found in, so the list reads the way the user's Mac
    /// is laid out. A server in two clients appears under both — that is the point.
    private struct ClientGroup {
        var client: ClientID
        var name: String
        var servers: [ServerSummary]
    }

    private func groups(_ p: SyncPreview) -> [ClientGroup] {
        let names = Dictionary(daemon.installedClients.map { ($0.id, $0.displayName) },
                               uniquingKeysWith: { a, _ in a })
        let clients = Set(p.adopted.flatMap(\.clients)).sorted()
        return clients.map { client in
            ClientGroup(client: client, name: names[client] ?? client.rawValue,
                  servers: p.adopted.filter { $0.clients.contains(client) })
        }
    }

    private func clientGroup(_ group: ClientGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(group.name.uppercased())
                .font(Typography.label)
                .tracking(Typography.labelTracking)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(group.servers) { server in
                    HStack(spacing: Space.s) {
                        ServerIcon(name: server.name, kind: server.kind, size: 22)
                        Text(server.name)
                            .font(Typography.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Space.s)
                        Text(server.kind.rawValue)
                            .font(Typography.caption)
                            .foregroundStyle(.tertiary)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, Space.xs)
            .cardSurface(cornerRadius: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.name), \(group.servers.count) servers, all selected")
    }

    private func foundLabel(_ p: SyncPreview) -> String {
        guard !p.adopted.isEmpty else {
            return "No servers found in your clients yet. Importing sets MCP Manager up anyway — "
                + "add servers from the main window whenever you like."
        }
        let clients = Set(p.adopted.flatMap(\.clients)).count
        return "Found \(count(p.adopted.count, "server")) across \(count(clients, "client"))."
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The honest half of the preview: which config files this would touch, and how. A collision
    /// between two clients shows up here as a "changed" entry — one of them is about to be
    /// rewritten to match the other, which is the whole reason for asking first.
    private func changes(_ p: SyncPreview) -> some View {
        DisclosureGroup(isExpanded: $showChanges) {
            VStack(alignment: .leading, spacing: Space.s) {
                if p.writes.isEmpty {
                    Text("No files will be modified.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(p.writes) { write in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clientName(write.client)).font(Typography.caption).bold()
                            changeLine("Added", write.adds, color: .green)
                            changeLine("Removed", write.removes, color: .red)
                            changeLine("Rewritten to match another client", write.changes, color: .orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.xs)
        } label: {
            HStack(spacing: Space.xs) {
                Text("Changes to your config files").font(Typography.caption)
                Text(writeSummary(p))
                    .font(Typography.caption)
                    .foregroundStyle(p.writes.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
        }
        .padding(Space.m)
        .cardSurface(cornerRadius: 12)
    }

    private func writeSummary(_ p: SyncPreview) -> String {
        p.writes.isEmpty ? "— none" : "— \(count(p.writes.count, "file"))"
    }

    @ViewBuilder private func changeLine(_ label: String, _ names: [String], color: Color) -> some View {
        if !names.isEmpty {
            Text("\(label): \(names.joined(separator: ", "))")
                .font(Typography.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clientName(_ id: ClientID) -> String {
        daemon.installedClients.first { $0.id == id }?.displayName ?? id.rawValue
    }

    // MARK: step 3 — done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Image(systemName: "powerplug.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Look for the plug in your menu bar.")
                    .font(.system(size: 15, weight: .medium))
                Text("It turns servers on and off per client, and goes yellow when something needs "
                     + "a sign-in. MCP Manager keeps working after you close this window.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: Space.s) {
            if step == .importing {
                Button("Back") { step = .service }
            }
            Spacer(minLength: Space.m)
            if step != .done {
                Button("Not now") { dismiss() }
            }
            primaryButton
        }
        .padding(Space.l)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .service:
            Button("Continue") { step = .importing }
                .keyboardShortcut(.defaultAction)
        case .importing:
            Button(importing ? "Importing…" : "Import") { runImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(importing || !canImport)
        case .done:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Only when we know what would happen. A preview we couldn't read means the daemon isn't
    /// answering, and an Import that can't say what it would do is the thing this sheet exists to
    /// prevent.
    private var canImport: Bool {
        if case .loaded = preview { return daemon.isConnected }
        return false
    }

    // MARK: actions

    private func load() async {
        guard daemon.isConnected else { return }
        do { preview = .loaded(try await daemon.importPreview()) }
        catch { preview = .failed(String(describing: error)) }
    }

    private func runImport() {
        importing = true
        Task {
            defer { importing = false }
            if await daemon.confirmImport() { step = .done }
        }
    }
}
