import SwiftUI
import MCPMCore
import MCPMControl

/// The main window: filters and search across the top, a grid of server cards, and an inspector
/// that is always open on the right. Selection lives here because both the grid and the inspector
/// need it; everything else about a server is read straight from the daemon's status.
struct MainWindowView: View {
    @Environment(DaemonClient.self) private var daemon

    @State private var selection: String?
    @State private var clientFilter: ClientID?
    @State private var kindFilter: ServerKind?
    @State private var query = ""
    @State private var showAdd = false
    @State private var showRemove = false

    private var selected: ServerStatus? {
        guard let selection else { return nil }
        return daemon.status?.servers.first { $0.id == selection }
    }

    /// Name match AND kind AND, under a client filter, on in that client. A few dozen servers, so
    /// this is cheap enough to do while the view builds.
    private var filtered: [ServerStatus] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return daemon.servers(filter: clientFilter).filter { st in
            if !needle.isEmpty, !st.server.name.lowercased().contains(needle) { return false }
            if let kindFilter, st.server.kind != kindFilter { return false }
            if let clientFilter, !daemon.isEnabled(st.server, for: clientFilter) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            body(of: daemon.status)
            banners
        }
        .inspector(isPresented: .constant(true)) {
            InspectorView(serverID: selection, clear: { selection = nil })
                .inspectorColumnWidth(min: 250, ideal: 280, max: 320)
        }
        .sheet(isPresented: $showAdd) { AddServerSheet().environment(daemon) }
        .confirmationDialog("Remove server?", isPresented: $showRemove, presenting: selected) { st in
            Button("Remove \(st.server.name)", role: .destructive) {
                daemon.remove(st.server.id)
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { st in
            Text("Remove \(st.server.name) from all clients?")
        }
        .onDeleteCommand { if selected != nil { showRemove = true } }
        .onAppear { daemon.start() }
    }

    // MARK: header

    private var header: some View {
        GlassEffectContainer(spacing: Space.s) {
            HStack(spacing: Space.s) {
                clientMenu
                kindMenu
                Text("\(filtered.count) \(filtered.count == 1 ? "server" : "servers")")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.m)
                search
                Button("Add", systemImage: "plus") { showAdd = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!daemon.isConnected)
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
            Text(clientLabel).font(Typography.body)
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
            Text(kindFilter?.rawValue ?? "All kinds").font(Typography.body)
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
                .font(Typography.body)
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
    @ViewBuilder private func body(of status: DaemonStatus?) -> some View {
        if status != nil {
            grid
                .disabled(!daemon.isConnected)
                .opacity(daemon.isConnected ? 1 : 0.5)
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

    @ViewBuilder private var grid: some View {
        if filtered.isEmpty {
            spacerView(ContentUnavailableView(
                daemon.status?.servers.isEmpty == true ? "No servers yet" : "No matching servers",
                systemImage: "square.grid.2x2",
                description: Text(daemon.status?.servers.isEmpty == true
                                  ? "Add one with the + button." : "Try a different filter or search.")))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(filtered) { st in
                        ServerCard(status: st, clients: daemon.installedClients,
                                   selected: st.id == selection) { selection = st.id }
                    }
                }
                .padding(Space.l)
            }
        }
    }

    // MARK: banners

    @ViewBuilder private var banners: some View {
        if let why = daemon.disconnectReason, daemon.status != nil {
            banner("Background service unreachable — \(why)", color: .red)
        }
        if let err = daemon.lastError {
            banner(err, color: .red)
        }
        // The daemon's own last failure — a sync or write that went wrong with nobody watching —
        // as opposed to the command we just sent.
        if let err = daemon.status?.lastError {
            banner("Background service: \(err)", color: .orange)
        }
        ForEach(daemon.installedClients.filter { !$0.healthy }) { client in
            banner("\(client.displayName) config could not be parsed — not syncing to it. \(client.error ?? "")",
                   color: .orange)
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Typography.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .padding(.horizontal, Space.l)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
