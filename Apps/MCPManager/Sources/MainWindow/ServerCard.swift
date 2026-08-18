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
        .cardSurface(selected: selected, hovering: hovering)
        .scaleEffect(scale)
        .animation(.snappy(duration: 0.18), value: scale)
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
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
                .font(Typography.caption)
                .foregroundStyle(.yellow)
                .lineLimit(1)
        } else {
            HStack(spacing: Space.xs) {
                Text(status.server.subline)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Signed in and working. A dot rather than a word, because the card's job is to say
                // which server this is and the subline already carries the sentence.
                if status.authStatus == .connected {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Signed in")
                }
            }
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
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .animation(.snappy(duration: 0.15), value: on)
        .help(on ? "Enabled in \(client.displayName) — click to turn off"
                 : "Disabled in \(client.displayName) — click to turn on")
        .accessibilityLabel("\(client.displayName), \(on ? "enabled" : "disabled")")
    }
}
