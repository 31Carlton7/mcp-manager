import SwiftUI
import ServiceManagement
import MCPMCore
import MCPMControl

/// The main window: two tabs under one header — the library of servers, with filters, a grid of
/// cards and an inspector on the right, and the catalog of servers there are to add. Selection
/// lives here because both the grid and the inspector need it; everything else about a server is
/// read straight from the daemon's status.
struct MainWindowView: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(StartupSettings.self) private var startup

    /// Sticky per-user, not per-launch: someone who has said "not now" has answered the question.
    @AppStorage("dismissedStartupNudge") private var dismissedStartupNudge = false

    @State private var tab: Tab = .servers
    @State private var selection: String?
    @State private var clientFilter: ClientID?
    @State private var kindFilter: ServerKind?
    @State private var query = ""
    /// The Add sheet, and what it opens on. A fresh request each time, so a sheet opened from the
    /// catalog and one opened from the toolbar can never inherit each other's entry.
    @State private var addRequest: AddRequest?
    @State private var showRemove = false
    @State private var showOnboarding = false
    /// Set once the sheet has been offered, so dismissing it doesn't immediately re-present it.
    /// Not persisted: setup is unfinished until the daemon says otherwise, and the banner is what
    /// carries that between launches.
    @State private var offeredOnboarding = false
    /// ⌫ only means "remove" while the grid itself has focus — inside the search field it still
    /// deletes a character.
    @FocusState private var gridFocused: Bool

    enum Tab: String, CaseIterable { case servers = "Servers", catalog = "Catalog" }

    /// One press of Add. The id is what makes each press its own sheet rather than a re-run of the
    /// last one.
    private struct AddRequest: Identifiable {
        let id = UUID()
        var entry: CatalogEntry?
    }

    private var selected: ServerStatus? {
        guard let selection else { return nil }
        return daemon.status?.servers.first { $0.id == selection }
    }

    /// Name match AND kind AND, under a client filter, on in that client. A few dozen servers, so
    /// this is cheap enough to do while the view builds.
    private var filtered: [ServerStatus] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return daemon.servers.filter { st in
            if !needle.isEmpty, !st.server.name.lowercased().contains(needle) { return false }
            if let kindFilter, st.server.kind != kindFilter { return false }
            if let clientFilter, !daemon.isEnabled(st.server, for: clientFilter) { return false }
            return true
        }
    }

    var body: some View {
        // Filtering once per body: the header's count and the grid are the same list.
        let servers = filtered
        VStack(spacing: 0) {
            header(count: servers.count)
            Hairline()
            setupBanner
            startupNudge
            switch tab {
            case .servers: content(for: servers)
            case .catalog: CatalogView { entry in addRequest = AddRequest(entry: entry) }
            }
            banners
        }
        // On the container, not on the banner: a transition can only animate if the animation
        // outlives the view being inserted or removed.
        .animation(.snappy(duration: 0.2), value: showStartupNudge)
        .animation(.snappy(duration: 0.2), value: daemon.needsSetup)
        .animation(.snappy(duration: 0.2), value: tab)
        // The inspector is about a selected server, and the catalog has none to select.
        .inspector(isPresented: .constant(tab == .servers)) {
            InspectorView(serverID: selection, clear: { selection = nil })
                .inspectorColumnWidth(min: 250, ideal: 280, max: 320)
        }
        .sheet(item: $addRequest) { request in
            AddServerSheet(prefill: request.entry).environment(daemon)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet().environment(daemon).environment(startup)
        }
        // The daemon is the authority on whether setup is finished, and its first status arrives
        // after this window does — so the sheet waits for the answer rather than for onAppear.
        .onChange(of: daemon.needsSetup, initial: true) { _, needed in
            guard needed, !offeredOnboarding else { return }
            offeredOnboarding = true
            showOnboarding = true
        }
        .confirmationDialog("Remove server?", isPresented: $showRemove, presenting: selected) { st in
            Button("Remove \(st.server.name)", role: .destructive) {
                daemon.remove(st.server.id)
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { st in
            Text("Remove \(st.server.name) from all clients?")
        }
        // A server can leave under us — removed here, or deleted from every client's config on
        // disk — and a selection pointing at nothing would leave the inspector permanently empty.
        .onChange(of: daemon.status?.servers.map(\.id) ?? []) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onAppear {
            daemon.start()
            startup.refresh()
        }
    }

    // MARK: setup banner

    /// Stays up for as long as the daemon is holding the first import — dismissing the sheet
    /// postpones the question, it does not answer it, and until it is answered nothing on this
    /// Mac is being written to.
    @ViewBuilder private var setupBanner: some View {
        if daemon.needsSetup {
            NoticeBanner(text: "Setup not finished — your configs are untouched until you import.",
                         symbol: "hand.raised", tint: Semantic.orange) {
                Button("Finish setup") { showOnboarding = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.m)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: startup nudge

    /// The one thing a fresh install gets wrong on its own: the daemon only runs because the app
    /// started it, so the next reboot comes up with nothing running. Gone the moment the agent is
    /// enabled, whether from here or from System Settings.
    /// Suppressed while setup is unfinished: the onboarding sheet's first step asks the same
    /// question, and the setup banner is already holding that spot.
    private var showStartupNudge: Bool {
        !startup.daemonAtLogin && !dismissedStartupNudge && !daemon.needsSetup
    }
    private var needsApproval: Bool { startup.daemonStatus == .requiresApproval }

    @ViewBuilder private var startupNudge: some View {
        if showStartupNudge {
            // Registering again cannot clear an approval the user withheld — only they can, in
            // System Settings — so the banner asks for that instead of a button that no-ops.
            NoticeBanner(text: needsApproval
                         ? "Approve MCP Manager in System Settings → Login Items"
                         : "Start the background service at login so your servers survive restarts.",
                         symbol: "bolt.badge.clock", tint: Semantic.yellow) {
                HStack(spacing: Space.s) {
                    if needsApproval {
                        Button("Open Login Items") { startup.openLoginItemsSettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button("Enable") { startup.daemonAtLogin = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button("Not now") { dismissedStartupNudge = true }
                        .buttonStyle(.plain)
                        .font(Typography.listValue)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.m)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: header

    private func header(count: Int) -> some View {
        GlassEffectContainer(spacing: Space.s) {
            HStack(spacing: Space.s) {
                TabStrip(Tab.allCases, selection: $tab, title: \.rawValue)
                    .frame(width: 180)
                // The filters, the count and the search are all about the library; the catalog
                // brings its own search and has nothing to filter.
                if tab == .servers {
                    clientMenu
                    kindMenu
                    Text("\(count) \(count == 1 ? "server" : "servers")")
                        .font(Typography.listValue)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.m)
                if tab == .servers { search }
                Button("Add", systemImage: "plus") { addRequest = AddRequest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!daemon.isConnected)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        // `.hiddenTitleBar` puts the content under the window controls, so the row starts below them.
        .padding(.top, 30)
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.m)
    }

    private var clientMenu: some View {
        Menu {
            Button("All clients") { clientFilter = nil }
            ForEach(daemon.installedClients) { client in
                Button(client.displayName) { clientFilter = client.id }
            }
        } label: {
            Text(clientLabel).font(Typography.rowTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel("Client filter")
    }

    private var clientLabel: String {
        guard let clientFilter else { return "All clients" }
        return daemon.installedClients.first { $0.id == clientFilter }?.displayName ?? clientFilter.rawValue
    }

    private var kindMenu: some View {
        Menu {
            Button("All kinds") { kindFilter = nil }
            Button("stdio") { kindFilter = .stdio }
            Button("remote") { kindFilter = .remote }
        } label: {
            Text(kindFilter?.rawValue ?? "All kinds").font(Typography.rowTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel("Kind filter")
    }

    private var search: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.field)
                .frame(width: 150)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .pill()
        .fixedSize()
    }

    // MARK: grid

    /// The last status the daemon sent is still the best guess at the truth, so it stays on screen
    /// while disconnected — dimmed and inert, since editing it can't work.
    @ViewBuilder private func content(for servers: [ServerStatus]) -> some View {
        if daemon.status != nil {
            grid(servers)
                .disabled(!daemon.isConnected)
                .opacity(daemon.isConnected ? 1 : 0.5)
                .animation(.snappy(duration: 0.2), value: daemon.isConnected)
        } else if let why = daemon.disconnectReason {
            spacerView(ContentUnavailableView("Background service unreachable", systemImage: "powerplug",
                                              description: Text(why)))
        } else {
            spacerView(ContentUnavailableView("Connecting to background service…", systemImage: "powerplug"))
        }
    }

    private func spacerView(_ content: some View) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func grid(_ servers: [ServerStatus]) -> some View {
        if servers.isEmpty {
            spacerView(ContentUnavailableView(
                daemon.status?.servers.isEmpty == true ? "No servers yet" : "No matching servers",
                systemImage: "square.grid.2x2",
                description: Text(daemon.status?.servers.isEmpty == true
                                  ? "Add one with the + button." : "Try a different filter or search.")))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(servers) { st in
                        ServerCard(status: st, clients: daemon.installedClients,
                                   selected: st.id == selection) {
                            selection = st.id
                            gridFocused = true
                        }
                    }
                }
                .padding(Space.l)
            }
            // `onDeleteCommand` is only delivered to the focused responder, so the grid has to be
            // able to take focus — selecting a card gives it focus, and the accent border already
            // says which card ⌫ would remove, so the system focus ring would only be noise.
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onDeleteCommand { if selected != nil { showRemove = true } }
        }
    }

    // MARK: banners

    @ViewBuilder private var banners: some View {
        if let why = daemon.disconnectReason, daemon.status != nil {
            banner("Background service unreachable — \(why)", tint: Semantic.red)
        }
        if let err = daemon.lastError {
            banner(err, tint: Semantic.red)
        }
        // The daemon's own last failure — a sync or write that went wrong with nobody watching —
        // as opposed to the command we just sent.
        if let err = daemon.status?.lastError {
            banner("Background service: \(err)", tint: Semantic.orange)
        }
        ForEach(daemon.installedClients.filter { !$0.healthy }) { client in
            banner("\(client.displayName) config could not be parsed — not syncing to it. \(client.error ?? "")",
                   tint: Semantic.orange)
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        NoticeBanner(text, tint: tint)
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.s)
    }
}
