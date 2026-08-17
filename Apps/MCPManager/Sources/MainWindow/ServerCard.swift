import SwiftUI
import MCPMCore
import MCPMControl

extension Server {
    /// "remote · mcp.notion.com" / "stdio · npx" — what a card or the inspector says under the name.
    var subline: String {
        switch kind {
        case .stdio:
            return "stdio · \((command.map { ($0 as NSString).lastPathComponent }) ?? "no command")"
        case .remote:
            let host = URL(string: url ?? "")?.host
            return "remote · \(host ?? url ?? "no URL")"
        }
    }
}

/// One server in the grid: who it is on top, which clients it is on along the bottom. The chips are
/// buttons, so the common edit — turning a server on for one client — never needs the inspector.
struct ServerCard: View {
    let status: ServerStatus
    let clients: [ClientStatus]
    let selected: Bool
    let select: () -> Void

    @Environment(DaemonClient.self) private var daemon
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                ServerIcon(server: status.server, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.server.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    subline
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            chips
        }
        .padding(Space.m)
        .frame(height: 96, alignment: .topLeading)
        .glassCard(selected: selected)
        .overlay {
            // Selection is the accent border inside `glassCard`; hover only lifts the edge a little,
            // so the two can be on at once without fighting.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(hovering && !selected ? 0.18 : 0), lineWidth: 1)
        }
        .animation(.snappy(duration: 0.15), value: hovering)
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.server.name)
    }

    @ViewBuilder private var subline: some View {
        if status.state == "needsAuth" {
            Text("needs sign-in")
                .font(Typography.caption)
                .foregroundStyle(.yellow)
                .lineLimit(1)
        } else {
            Text(status.server.subline)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var chips: some View {
        HStack(spacing: Space.xs) {
            ForEach(clients) { chip($0) }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ client: ClientStatus) -> some View {
        let on = daemon.isEnabled(status.server, for: client.id)
        return Button {
            daemon.setClient(status.server.id, client.id, !on)
        } label: {
            Text(client.displayName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(on ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(on ? Color.green.opacity(0.18) : Color.primary.opacity(0.06), in: .capsule)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: on)
        .help(on ? "Enabled in \(client.displayName) — click to turn off"
                 : "Disabled in \(client.displayName) — click to turn on")
        .accessibilityLabel("\(client.displayName), \(on ? "enabled" : "disabled")")
    }
}
