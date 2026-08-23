import SwiftUI
import MCPMCore
import MCPMControl

/// The catalog tab: a curated list to browse and the official registry to search, with an Add on
/// every card that opens the Add sheet already filled in. Nothing here is added directly — the
/// sheet is where a server gets its name, its clients and its auth, and where the URL is checked.
struct CatalogView: View {
    /// Hands an entry to the main window, which opens the Add sheet on it.
    let add: (CatalogEntry) -> Void

    @Environment(DaemonClient.self) private var daemon

    @State private var query = ""
    @State private var entries: [CatalogEntry] = []
    /// The list the empty query answered with — the one that ships inside the daemon. Kept so a
    /// search that can't reach the service still has something true to show.
    @State private var curated: [CatalogEntry] = []
    @State private var loading = false
    /// The last search never reached the registry, so what is on screen is the curated list alone.
    @State private var offline = false
    /// The service couldn't answer at all and there is no curated list to fall back on.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            searchField
            offlineNote
            results
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        // Keyed on the query, so a keystroke cancels the search the last one started and the
        // answer to a query nobody is looking at any more is never shown.
        .task(id: query) { await search() }
        .animation(.snappy(duration: 0.2), value: offline)
    }

    // MARK: search

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchField: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search the MCP registry", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
            if loading {
                ProgressView().controlSize(.mini)
            } else if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .pill()
    }

    @ViewBuilder private var offlineNote: some View {
        if offline {
            Label("Registry unreachable — showing the curated list", systemImage: "bolt.horizontal")
                .font(Typography.caption)
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
    }

    /// The empty query is the curated list and answers instantly, so only a typed one waits — a
    /// search per keystroke would be a request per keystroke, most of them already stale.
    private func search() async {
        let query = trimmedQuery
        loading = true
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        do {
            let found = try await daemon.searchCatalog(query: query)
            guard !Task.isCancelled else { return }
            entries = found
            if query.isEmpty { curated = found }
            offline = false
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            // The curated list is bundled, so it is still true when nothing can be reached; only
            // when we never got even that is there nothing to show.
            if curated.isEmpty {
                failure = reason(error)
            } else {
                entries = matching(curated, query: query)
                offline = true
            }
        }
        loading = false
    }

    private func matching(_ entries: [CatalogEntry], query: String) -> [CatalogEntry] {
        guard !query.isEmpty else { return entries }
        let needle = query.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(needle) || $0.slug.contains(needle)
                || $0.description.lowercased().contains(needle)
        }
    }

    private func reason(_ error: Error) -> String {
        if case ControlClientError.remote(let why) = error { return why }
        return String(describing: error)
    }

    // MARK: results

    @ViewBuilder private var results: some View {
        if let failure {
            spacer(ContentUnavailableView("Catalog unavailable", systemImage: "books.vertical",
                                          description: Text(failure)))
        } else if entries.isEmpty {
            if loading {
                spacer(ProgressView())
            } else {
                spacer(ContentUnavailableView("Nothing found", systemImage: "magnifyingglass",
                                              description: Text(trimmedQuery.isEmpty
                                                                ? "The catalog is empty."
                                                                : "No server matches “\(trimmedQuery)”.")))
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    ForEach(entries) { entry in
                        CatalogCard(entry: entry, added: alreadyInLibrary(entry)) { add(entry) }
                    }
                }
                .padding(.vertical, Space.s)
            }
        }
    }

    private func spacer(_ content: some View) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether the library already has this server: the same endpoint, the same command line, or
    /// the same name. Nothing stops a second copy — the daemon would take it — but a card that
    /// says "Added" is the answer to the question the user is actually asking.
    private func alreadyInLibrary(_ entry: CatalogEntry) -> Bool {
        daemon.servers.contains { status in
            let server = status.server
            if server.name.caseInsensitiveCompare(entry.name) == .orderedSame { return true }
            if let url = entry.url, let mine = server.url { return endpoint(url) == endpoint(mine) }
            guard entry.kind == .stdio, let command = entry.command, let mine = server.command
            else { return false }
            return basename(mine) == basename(command) && server.args == entry.args
        }
    }

    /// Two spellings of one endpoint — a trailing slash, a capitalised host — are one endpoint.
    private func endpoint(_ raw: String) -> String {
        var text = raw.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func basename(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// One catalog entry: who it is, what it is, and whether it is already in the library. The same
/// card surface as a server card — the grid it sits in is the same grid.
private struct CatalogCard: View {
    let entry: CatalogEntry
    let added: Bool
    let add: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                ServerIcon(name: entry.name, kind: entry.kind, url: entry.url,
                           command: entry.command, args: entry.args, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.description.isEmpty ? "No description" : entry.description)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Space.m)
        .frame(height: 112, alignment: .topLeading)
        .cardSurface(hovering: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(sourceLabel), \(authLabel)")
    }

    private var footer: some View {
        HStack(spacing: Space.xs) {
            badge(transportLabel, tint: .secondary)
            badge(sourceLabel, tint: entry.source == .registry && entry.official
                  ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
            badge(authLabel, tint: entry.auth == .none
                  ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.yellow))
            Spacer(minLength: Space.xs)
            if added {
                Label("Added", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func badge(_ text: String, tint: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: .capsule)
    }

    /// "stdio" / "remote" / "remote · sse" — the transport only shows when it isn't the default.
    private var transportLabel: String {
        guard entry.kind == .remote else { return "stdio" }
        return entry.transport == .sse ? "remote · sse" : "remote"
    }

    private var sourceLabel: String {
        switch entry.source {
        case .bundled: "curated"
        case .registry: entry.official ? "official" : "community"
        }
    }

    private var authLabel: String {
        switch entry.auth {
        case .none: "No auth"
        case .oauth: "Sign in"
        case .header: "API key"
        }
    }
}
