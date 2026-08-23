import AppKit
import SwiftUI
import MCPMCore
import MCPMControl

extension DaemonClient.Health {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .yellow
        case .error: .red
        }
    }
}

/// The status item itself. Menu bar images are template-rendered, so the tint can be ignored;
/// the badge is what reliably carries a warning or an error into the menu bar.
struct MenuBarLabel: View {
    @Environment(DaemonClient.self) private var daemon
    @Environment(\.openWindow) private var openWindow

    /// Once per launch. A user who closes the setup window has said "not now" for this run; the
    /// popover's row and the window's banner are what keep asking after that.
    @State private var offeredSetup = false

    var body: some View {
        Image(systemName: "powerplug.fill")
            .foregroundStyle(daemon.health.color)
            .overlay(alignment: .topTrailing) {
                if daemon.health != .ok {
                    Circle().fill(daemon.health.color)
                        .frame(width: 4, height: 4)
                        .offset(x: 2, y: -1)
                }
            }
            .onAppear { daemon.start() }
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

    @Environment(DaemonClient.self) private var daemon
    @Environment(\.openWindow) private var openWindow

    @State private var filter: ClientID?
    @State private var tab: Tab = .servers

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            heroes
            setupRow
            Hairline()
            TextTabs(Tab.allCases, selection: $tab, title: \.rawValue)
            list
                .disabled(!daemon.isConnected)
                .opacity(daemon.isConnected ? 1 : 0.5)
            errors
            Hairline()
            footer
        }
        .padding(Space.l)
        .frame(width: 330)
        .onAppear { daemon.start() }
    }

    // MARK: header

    private var header: some View {
        GlassEffectContainer(spacing: Space.s) {
            HStack(spacing: Space.s) {
                if let why = daemon.disconnectReason {
                    Text("Background service unreachable")
                        .font(Typography.body)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(why)
                } else {
                    filterMenu
                }
                Spacer(minLength: Space.s)
                settingsMenu
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("All clients") { filter = nil }
            ForEach(daemon.installedClients) { client in
                Button(client.displayName) { filter = client.id }
            }
        } label: {
            Text(filterLabel).font(Typography.body)
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The background service keeps running after you quit")
        .accessibilityLabel("Settings")
    }

    // MARK: heroes

    private var heroes: some View {
        let attention = daemon.attentionCount
        return HStack(alignment: .top, spacing: 28) {
            HeroNumber(title: "Active", value: daemon.activeCount(filter: filter))
            HeroNumber(title: "Clients", value: daemon.installedClients.count)
            HeroNumber(title: "Needs attention", value: attention, tint: attention > 0 ? .yellow : .secondary)
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
                HStack(spacing: Space.xs) {
                    Image(systemName: "hand.raised")
                    Text("Setup not finished — nothing has been imported")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.xs)
                    Text("Finish setup ↗")
                }
                .font(Typography.caption)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.14), in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.orange)
        }
    }

    // MARK: list

    /// A plain `VStack` rather than a lazy one: the list is at most a few dozen rows and it has to
    /// report its full height so the popover can shrink to fit it.
    @ViewBuilder private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
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
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.2), value: daemon.isConnected)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Typography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.s)
    }

    private func serverRow(_ st: ServerStatus) -> some View {
        HStack(spacing: Space.s) {
            ServerIcon(server: st.server, size: 26)
            Text(st.server.name)
                .font(Typography.body)
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
        .padding(.vertical, 3)
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
            HStack(spacing: 3) {
                Text("Sign in")
                if off {
                    Text("(gateway off)").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.yellow.opacity(off ? 0.08 : 0.18), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .foregroundStyle(off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.yellow))
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
        return HStack(spacing: Space.s) {
            Circle()
                .fill(client.healthy ? Color.green : Color.red)
                .frame(width: 6, height: 6)
                .help(client.error ?? (client.healthy ? "Healthy" : "Unhealthy"))
            Text(client.displayName).font(Typography.body).lineLimit(1)
            Text("\(count) servers").font(Typography.caption).foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            Button("Re-import") { daemon.reimport(client.id) }
                .font(Typography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Read \(client.configPath) back into the library")
        }
        .padding(.vertical, 6)
    }

    // MARK: errors and footer

    @ViewBuilder private var errors: some View {
        if let err = daemon.lastError {
            Text(err).font(Typography.caption).foregroundStyle(.red).lineLimit(3)
        }
        // The daemon's own last failure — a sync or write that went wrong with nobody watching —
        // as opposed to the command we just sent.
        if let err = daemon.status?.lastError {
            Text("Background service: \(err)").font(Typography.caption).foregroundStyle(.orange).lineLimit(3)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            Text(syncedLabel)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            // `SettingsLink` rather than a button: only it can bring the Settings scene forward
            // from a menu bar popover in an LSUIElement app, which has no menu bar of its own.
            SettingsLink { Text("Settings…") }
                .font(Typography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button("Open MCP Manager ↗") { open() }
                .font(Typography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
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
