import AppKit
import SwiftUI
import MCPMCore
import MCPMControl

extension DaemonClient.Health {
    var color: Color {
        switch self {
        case .ok: Semantic.green
        case .warning: Semantic.yellow
        case .error: Semantic.red
        }
    }
}

/// The status item itself. Menu bar images are template-rendered, so the tint can be ignored;
/// the badge is what reliably carries a warning or an error into the menu bar.
struct MenuBarLabel: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(StartupSettings.self) private var startup
    @Environment(\.openWindow) private var openWindow

    /// Once per launch. A user who closes the setup window has said "not now" for this run; the
    /// popover's row and the window's banner are what keep asking after that.
    @State private var offeredSetup = false

    var body: some View {
        // A template PDF (Resources/Assets.xcassets/MenuBarIcon, drawn by
        // scripts/render-menubar-icon.swift): macOS recolours it for the bar's appearance, like the
        // system glyphs beside it. Health is a small dot at the bottom-right corner, hidden when ok.
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .frame(width: 18, height: 18)
            .overlay(alignment: .bottomTrailing) {
                if daemon.health != .ok {
                    Circle().fill(daemon.health.color)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityLabel("MCP Manager")
            .task {
                daemon.start()
                // A service that is registered and meant to be running, but hasn't answered by
                // now, is usually launchd refusing to spawn a rebuilt binary. Rebinding the login
                // item fixes that; the connect loop is still retrying and picks it up from there.
                try? await Task.sleep(for: .seconds(6))
                // The capture build runs against a scratch home and must never touch the login
                // item record, which belongs to the copy the user actually installed.
                guard !DemoCapture.isActive else { return }
                guard !Task.isCancelled, !daemon.isConnected, startup.daemonAtLogin else { return }
                await startup.rebindDaemonIfStale()
            }
            // This view is the only one built at launch — the popover's content isn't — so it is
            // where an unfinished setup has to be noticed. The window presents the sheet itself.
            .onChange(of: daemon.needsSetup) { _, needed in
                guard needed, !offeredSetup else { return }
                offeredSetup = true
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

/// The popover: a client filter, three hero numbers, and one list that is either the servers or
/// the clients behind them.
struct MenuBarView: View {
    private enum Tab: String, CaseIterable { case servers = "Servers", clients = "Clients" }

    /// Fixed width, 12 pt of frame padding, and so a 308 pt content column. Nothing inside reflows,
    /// which is what makes the absolute column widths below safe.
    private static let width: CGFloat = 332
    /// What sits above and below the scroll region — header, heroes, tabs, footer — budgeted as a
    /// constant so the list can take everything the screen has left and no more.
    private static let chrome: CGFloat = 240

    @Environment(DaemonClient.self) private var daemon
    @Environment(\.openWindow) private var openWindow

    @State private var filter: ClientID?
    @State private var tab: Tab = .servers

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            heroes
            setupRow
            TabStrip(Tab.allCases, selection: $tab, title: \.rawValue)
            list
                .disabled(!daemon.isConnected)
                .opacity(daemon.isConnected ? 1 : 0.5)
            errors
            footer
        }
        .padding(Space.m)
        .frame(width: Self.width)
        .onAppear { daemon.start() }
    }

    // MARK: header

    /// A fixed-height band, 28 pt of content inside 4 pt of vertical padding, with a leading slot
    /// and a trailing icon button. We leave the middle empty on purpose: the observed pattern puts
    /// a brand mark here, and our identity is the menu bar icon.
    private var header: some View {
        GlassEffectContainer(spacing: Space.s) {
            HStack(spacing: Space.s) {
                if let why = daemon.disconnectReason {
                    Text("Background service unreachable")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Semantic.red)
                        .lineLimit(1)
                        .help(why)
                } else {
                    filterMenu
                }
                Spacer(minLength: Space.s)
                settingsMenu
            }
            .frame(height: 28)
        }
        .padding(.vertical, Space.xs)
    }

    private var filterMenu: some View {
        Menu {
            Button("All clients") { filter = nil }
            ForEach(daemon.installedClients) { client in
                Button(client.displayName) { filter = client.id }
            }
        } label: {
            Text(filterLabel).font(Typography.rowTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel("Client filter")
    }

    private var filterLabel: String {
        guard let filter else { return "All clients" }
        return daemon.installedClients.first { $0.id == filter }?.displayName ?? filter.rawValue
    }

    /// Everything that isn't about a single server: opening the window, and quitting the app
    /// without stopping the background service.
    private var settingsMenu: some View {
        Menu {
            Button("Open MCP Manager…") { open() }
            Divider()
            Button("Quit MCP Manager") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .circleGlassButton()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The background service keeps running after you quit")
        .accessibilityLabel("Settings")
    }

    // MARK: heroes

    private var heroes: some View {
        let attention = daemon.attentionCount
        return HStack(alignment: .top, spacing: Space.xl) {
            HeroNumber(title: "Active", value: daemon.activeCount(filter: filter))
            HeroNumber(title: "Clients", value: daemon.installedClients.count)
            HeroNumber(title: "Needs attention", value: attention,
                       tint: attention > 0 ? Semantic.yellow : .secondary)
            Spacer(minLength: 0)
        }
        .opacity(daemon.isConnected ? 1 : 0.4)
        .animation(.snappy(duration: 0.2), value: daemon.isConnected)
    }

    /// Setup lives in the main window — this is the one line of it the popover carries, since the
    /// hero numbers above read as zero for a reason the user is owed.
    @ViewBuilder private var setupRow: some View {
        if daemon.needsSetup {
            Button { open() } label: {
                NoticeBanner(text: "Setup not finished — nothing has been imported",
                             symbol: "hand.raised", tint: Semantic.orange, limit: 2) {
                    Text("Finish setup ↗")
                        .font(Typography.listValue)
                        .foregroundStyle(Semantic.orange)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.pressable)
        }
    }

    // MARK: list

    /// A plain `VStack` rather than a lazy one: the list is at most a few dozen rows and it has to
    /// report its full height so the popover can shrink to fit it.
    @ViewBuilder private var list: some View {
        ScrollView {
            VStack(spacing: Space.xs) {
                switch tab {
                case .servers:
                    let servers = daemon.servers
                    if servers.isEmpty {
                        empty("No servers yet")
                    } else {
                        ForEach(servers) { serverRow($0) }
                    }
                case .clients:
                    let clients = daemon.installedClients
                    if clients.isEmpty {
                        empty("No supported clients installed")
                    } else {
                        ForEach(clients) { clientRow($0) }
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: Self.listMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.2), value: daemon.isConnected)
    }

    /// The chrome is a constant; the list gets whatever the screen has left, and never less than
    /// 80 pt. With one client configured the popover ends up genuinely short.
    private static var listMaxHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 800
        return max(80, available - chrome)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Typography.rowCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.s)
    }

    /// Each row is its own plate, and the columns inside it are fixed: a 22 pt icon column, a
    /// flexible name, and a trailing control that always lands in the same place.
    private func serverRow(_ st: ServerStatus) -> some View {
        HStack(spacing: 9) {
            ServerIcon(server: st.server, size: 22)
            Text(st.server.name)
                .font(Typography.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            if st.authStatus == .needsAuth {
                signIn(st)
            }
            Spacer(minLength: Space.s)
            Toggle(st.server.name, isOn: enabled(st.server))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, 7)
        .cardSurface(cornerRadius: Radius.plate)
        // The "Sign in" badge appears and disappears with the daemon's status pushes, so it fades
        // rather than popping into the middle of the row.
        .animation(.snappy(duration: 0.2), value: st.state)
    }

    /// The one row-level action there is. With no gateway there is nothing to sign in to, and a
    /// disabled control can't be hovered for an explanation — so the row says why in the open.
    @ViewBuilder private func signIn(_ st: ServerStatus) -> some View {
        let off = daemon.gatewayPort == nil
        Button {
            daemon.startAuth(st.server.id)
        } label: {
            StatusPill(text: off ? "Sign in (gateway off)" : "Sign in",
                       tint: off ? .secondary : Semantic.yellow, compact: true)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .disabled(off)
        .accessibilityLabel(off ? "Sign in unavailable, gateway off"
                                : "Sign in to \(st.server.name)")
    }

    /// One switch, two meanings: with no filter it is the master switch for every installed
    /// client, and under a filter it is that client's flag. Both read through the optimistic
    /// overlay so the switch moves under the pointer.
    private func enabled(_ server: Server) -> Binding<Bool> {
        if let filter {
            Binding(get: { daemon.isEnabled(server, for: filter) },
                    set: { daemon.setClient(server.id, filter, $0) })
        } else {
            Binding(get: { daemon.isEnabledAnywhere(server, installed: daemon.installedClients.map(\.id)) },
                    set: { daemon.setAll(server.id, $0) })
        }
    }

    private func clientRow(_ client: ClientStatus) -> some View {
        let count = (daemon.status?.servers ?? []).count { daemon.isEnabled($0.server, for: client.id) }
        return HStack(spacing: 9) {
            StatusDot(tint: client.healthy ? Semantic.green : Semantic.red)
                .frame(width: 22)
                .help(client.error ?? (client.healthy ? "Healthy" : "Unhealthy"))
            Text(client.displayName)
                .font(Typography.rowTitle)
                .lineLimit(1)
            Text("\(count) servers")
                .font(Typography.listValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            Button("Re-import") { daemon.reimport(client.id) }
                .font(Typography.listValue)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Read \(client.configPath) back into the library")
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, 7)
        .cardSurface(cornerRadius: Radius.plate)
    }

    // MARK: errors and footer

    @ViewBuilder private var errors: some View {
        if let err = daemon.lastError {
            NoticeBanner(err, tint: Semantic.red, limit: 3)
        }
        // The daemon's own last failure — a sync or write that went wrong with nobody watching —
        // as opposed to the command we just sent.
        if let err = daemon.status?.lastError {
            NoticeBanner("Background service: \(err)", tint: Semantic.orange, limit: 3)
        }
    }

    /// Two quiet actions in equal halves, and never a primary one. The sync line sits above rather
    /// than inside, so the halves stay equal.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(syncedLabel)
                .font(Typography.rowCaption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack(spacing: Space.s) {
                // `SettingsLink` rather than a button: only it can bring the Settings scene forward
                // from a menu bar popover in an LSUIElement app, which has no menu bar of its own.
                SettingsLink { Text("Settings…").footerAction() }
                    .buttonStyle(.plain)
                Button { open() } label: { Text("Open MCP Manager ↗").footerAction() }
                    .buttonStyle(.plain)
            }
            .frame(height: 30)
        }
        .padding(.top, Space.xs)
    }

    private var syncedLabel: String {
        guard let date = daemon.lastSynced else { return "Not synced yet" }
        return "Synced \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
