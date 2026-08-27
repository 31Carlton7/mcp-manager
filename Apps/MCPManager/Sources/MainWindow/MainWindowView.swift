import SwiftUI
import ServiceManagement
import MCPMCore
import MCPMControl

/// Two tabs under one header: the library of servers as a grid with an inspector, and the catalog
/// of servers there are to add. Selection lives here because both the grid and the inspector need
/// it; everything else about a server is read straight from the daemon's status.
struct MainWindowView: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(StartupSettings.self) private var startup

    /// Sticky per-user: someone who has said "not now" has answered the question.
    @AppStorage("dismissedStartupNudge") private var dismissedStartupNudge = false

    @State private var tab: Tab = .servers
    @State private var selection: String?
    @State private var clientFilter: ClientID?
    @State private var kindFilter: ServerKind?
    @State private var query = ""
    @State private var addRequest: AddRequest?
    @State private var showRemove = false
    @State private var showOnboarding = false
    /// Set once the sheet has been offered, so dismissing it doesn't immediately re-present it.
    /// Not persisted: the banner is what carries an unfinished setup between launches.
    @State private var offeredOnboarding = false
    /// ⌫ only means "remove" while the grid itself has focus — inside the search field it still
    /// deletes a character.
    @FocusState private var gridFocused: Bool

    enum Tab: String, CaseIterable { case servers = "Servers", catalog = "Catalog" }

    /// One press of Add. The fresh id is what makes each press its own sheet, so a sheet opened
    /// from the catalog and one opened from the toolbar can never inherit each other's entry.
    private struct AddRequest: Identifiable {
        let id = UUID()
        var entry: CatalogEntry?
    }

    private var selected: ServerStatus? {
        guard let selection else { return nil }
        return daemon.status?.servers.first { $0.id == selection }
    }

    /// Name match AND kind AND, under a client filter, on in that client. A few dozen servers at
    /// most, which is why this can run in `body` rather than being cached on the model.
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
        // The header's count and the grid are the same list.
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
        // Binding the presentation to the selection rather than the tab both returns the width to
        // the grid and lets the system's close affordance clear the selection.
        .inspector(isPresented: Binding(
            get: { tab == .servers && selection != nil },
            set: { if !$0 { selection = nil } }
        )) {
            InspectorView(serverID: selection, clear: { selection = nil })
                .inspectorColumnWidth(min: 250, ideal: 280, max: 320)
        }
        .sheet(item: $addRequest) { request in
            AddServerSheet(prefill: request.entry).environment(daemon)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet().environment(daemon).environment(startup)
        }
        // The daemon's first status arrives after this window does, so the sheet waits for the
        // answer rather than for onAppear.
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
        // A selection pointing at a server that has left would leave the inspector empty for good.
        .onChange(of: daemon.status?.servers.map(\.id) ?? []) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onAppear {
            daemon.start()
            startup.refresh()
            installDemoHooks()
        }
    }

    /// Demo capture only; see DemoCapture.swift.
    private func installDemoHooks() {
        guard DemoCapture.isActive else { return }
        DemoHooks.showServers = { self.tab = .servers }
        DemoHooks.showCatalog = { self.tab = .catalog }
        DemoHooks.select = { self.selection = $0 }
        DemoHooks.openAdd = { self.addRequest = AddRequest(entry: $0) }
        DemoHooks.closeAdd = { self.addRequest = nil }
    }

    // MARK: setup banner

    /// Stays up for as long as the daemon is holding the first import: dismissing the sheet
    /// postpones the question rather than answering it, and until it is answered nothing on this
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

    /// A fresh install's daemon runs only because the app started it, so the next reboot comes up
    /// with nothing running. Suppressed while setup is unfinished — the onboarding sheet's first
    /// step asks the same question, and the setup banner is already holding that spot.
    private var showStartupNudge: Bool {
        !startup.daemonAtLogin && !dismissedStartupNudge && !daemon.needsSetup
    }
    private var needsApproval: Bool { startup.daemonStatus == .requiresApproval }

    @ViewBuilder private var startupNudge: some View {
        if showStartupNudge {
            // Registering again cannot clear an approval the user withheld, so under
            // `.requiresApproval` the banner points at System Settings instead of at a no-op.
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
                    .fixedSize()
                    .layoutPriority(2)
                // The catalog brings its own search and has nothing to filter.
                if tab == .servers {
                    ClientFilterMenu(clients: daemon.installedClients, selection: $clientFilter)
                    kindMenu
                    // First thing to give way when the window narrows; the grid answers the
                    // same question.
                    Text("\(count) \(count == 1 ? "server" : "servers")")
                        .font(Typography.listValue)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: Space.m)
                if tab == .servers {
                    SearchField(prompt: "Search", text: $query, fieldWidth: 150)
                        .fixedSize()
                }
                Button("Add", systemImage: "plus") { addRequest = AddRequest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!daemon.isConnected)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .circleGlassButton()
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        // `.hiddenTitleBar` puts the content under the window controls, so the row starts below them.
        .padding(.top, 30)
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.m)
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
