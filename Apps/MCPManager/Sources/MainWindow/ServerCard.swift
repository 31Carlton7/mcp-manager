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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// True for as long as the mouse is down on the card. `@GestureState` so it can never stick on
    /// if the gesture is cancelled out from under us.
    @GestureState private var pressing = false

    /// Hover lifts the card a hair and a press pushes it back — a pointer-sized amount, not a
    /// bounce. Reduce Motion keeps the border feedback and drops the movement.
    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if pressing { return 0.99 }
        return hovering ? 1.01 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                ServerIcon(server: status.server, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.server.name)
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    subline
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            chips
        }
        .padding(Space.card)
        .frame(height: 96, alignment: .topLeading)
        .cardSurface(selected: selected, hovering: hovering)
        .scaleEffect(scale)
        .animation(.snappy(duration: 0.18), value: scale)
        .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        // A zero-distance drag rather than `onTapGesture`, because it also reports the press. The
        // chips are child buttons and so still win the click that lands on them.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
                .onEnded { value in
                    let slip = max(abs(value.translation.width), abs(value.translation.height))
                    if slip < 8 { select() }
                }
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.server.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    @ViewBuilder private var subline: some View {
        if status.authStatus == .needsAuth {
            Text("needs sign-in")
                .font(Typography.rowCaption)
                .foregroundStyle(Semantic.yellow)
                .lineLimit(1)
        } else if status.authStatus == .error {
            Text("sign-in error")
                .font(Typography.rowCaption)
                .foregroundStyle(Semantic.red)
                .lineLimit(1)
        } else {
            HStack(spacing: Space.xs) {
                Text(status.server.subline)
                    .font(Typography.rowCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Signed in and working. A dot rather than a word, because the card's job is to say
                // which server this is and the subline already carries the sentence.
                if status.authStatus == .connected {
                    StatusDot(tint: Semantic.green, size: 5, glow: false)
                        .accessibilityLabel("Signed in")
                }
            }
        }
    }

    /// Card chips answer "which clients", not "what are they called" — the short form keeps all
    /// four legible in a 220 pt card where the full names truncate into "Clau…".
    static func shortName(_ client: ClientStatus) -> String {
        switch client.id {
        case .claudeCode: "Code"
        case .claudeDesktop: "Desktop"
        case .cursor: "Cursor"
        case .codex: "Codex"
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
            // The status pill of the language, one step down in size: four of these have to fit
            // across a 220 pt card, and the dot is what carries the on/off reading anyway.
            StatusPill(text: Self.shortName(client), tint: on ? Semantic.green : .secondary,
                       dot: on, compact: true)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .animation(.snappy(duration: 0.15), value: on)
        .help(on ? "Enabled in \(client.displayName) — click to turn off"
                 : "Disabled in \(client.displayName) — click to turn on")
        .accessibilityLabel("\(client.displayName), \(on ? "enabled" : "disabled")")
    }
}
