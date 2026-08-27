import SwiftUI
import MCPMCore
import MCPMControl

// The vocabulary built on top of the tokens: the surfaces, the repeated composites, and the one
// button style.

extension View {
    /// Card-tier fill plus the shared hairline — grid cards, catalog plates, inspector groups, the
    /// onboarding choice rows.
    ///
    /// Spec adjustment, twice over. The design called for `glassEffect` here; glass samples and
    /// refracts whatever is behind it every frame, and the grid scrolls dozens of these at once, so
    /// cards are a tinted material and true glass stays on the header pills and the popover.
    /// Selection is a border rather than the observed accent *fill*, because a filled card would
    /// fight the client chips inside it for the same accent colour. Only the border changes with
    /// state, so selection and hover animate in place instead of swapping the surface out.
    func cardSurface(cornerRadius: CGFloat = Radius.card, selected: Bool = false,
                     hovering: Bool = false) -> some View {
        background(Surface.card, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cardBorder(selected: selected, hovering: hovering),
                                  lineWidth: selected ? 1 : Stroke.hairline)
            }
            .animation(.snappy(duration: 0.18), value: selected)
            .animation(.snappy(duration: 0.18), value: hovering)
    }

    /// The inset tier: paste wells, fields, anything that should read as a recess rather than as a
    /// plate sitting on top.
    func controlWell(cornerRadius: CGFloat = Radius.plate) -> some View {
        background(Surface.control, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: Stroke.hairline)
            }
    }

    /// Capsule glass, for the controls that float above content: header filter menus and search.
    ///
    /// The capture build takes the opaque form instead: `cacheDisplay` renders the view hierarchy
    /// without the window server, and a backdrop-sampling layer has nothing to sample there, so
    /// glass would photograph as a label floating on nothing. See DemoCapture.swift.
    @ViewBuilder func pill() -> some View {
        if DemoCapture.isActive {
            controlWell(cornerRadius: 999)
        } else {
            glassEffect(.regular, in: .capsule)
        }
    }

    /// The round icon button that floats above content — Settings in the window header, the menu in
    /// the popover — with the same capture-build substitution as `pill()`.
    @ViewBuilder func circleGlassButton() -> some View {
        if DemoCapture.isActive {
            buttonStyle(.bordered).buttonBorderShape(.circle)
        } else {
            buttonStyle(.glass).buttonBorderShape(.circle)
        }
    }

    /// A footer action: half the row, card fill under the shell's heavier hairline, content that
    /// shrinks before it truncates. The footer never carries a primary action, and this says so.
    func footerAction() -> some View {
        font(Typography.value)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Surface.card, in: .rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: Stroke.shell)
            }
            .contentShape(.rect)
    }
}

/// The resting edge is the shared hairline; hover warms it, and selection replaces it with the
/// accent so the two never fight for the same pixel.
private func cardBorder(selected: Bool, hovering: Bool) -> Color {
    if selected { return .accentColor.opacity(hovering ? 1 : 0.85) }
    return hovering ? .primary.opacity(0.18) : Surface.hairline
}

/// Press feedback for the small pressable things — chips, mostly, where `.plain` gives none.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// A rule between blocks *inside* one card. Cards themselves are separated by the gutter.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.16))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Typography.label)
            .tracking(Typography.labelTracking)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Neutral by default, and hued only where the hue means something — in which case it also takes
/// the stroked form.
struct MicroBadge: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text.uppercased())
            .font(Typography.microBadge)
            .tracking(Typography.microBadgeTracking)
            .lineLimit(1)
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint?.opacity(0.16) ?? Color.primary.opacity(0.08), in: .capsule)
            .overlay {
                if let tint {
                    Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
                }
            }
    }
}

/// A status in the semantic hue, carrying the only shadow in the design — 2 pt of its own colour,
/// which is what keeps it legible against a translucent card.
struct StatusDot: View {
    var tint: Color
    var size: CGFloat = 7
    /// Dropped in dense rows, where dots sit close enough to bleed into each other.
    var glow: Bool = true

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .shadow(color: glow ? tint.opacity(0.6) : .clear, radius: 2)
    }
}

/// The labelled form of the dot. `compact` is the card-chip size, because four of these have to fit
/// across a 220 pt card.
struct StatusPill: View {
    let text: String
    var tint: Color
    var dot: Bool = true
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            if dot {
                StatusDot(tint: tint, size: compact ? 5 : 7, glow: !compact)
            }
            Text(text)
                .font(compact ? Typography.rowCaption.weight(.medium) : Typography.value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.13), in: .capsule)
    }
}

/// The quiet notice bar: no colour in the fill, only in the glyph and whatever the caller trails
/// with, so an announcement never shouts louder than the content under it.
struct NoticeBanner<Trailing: View>: View {
    let text: String
    var symbol: String = "exclamationmark.triangle"
    var tint: Color = Semantic.red
    var limit: Int = 2
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(limit)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            trailing
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06),
                    in: .rect(cornerRadius: Radius.plate, style: .continuous))
    }
}

extension NoticeBanner where Trailing == EmptyView {
    init(_ text: String, symbol: String = "exclamationmark.triangle",
         tint: Color = Semantic.red, limit: Int = 2) {
        self.init(text: text, symbol: symbol, tint: tint, limit: limit) { EmptyView() }
    }
}

/// A big number under a small caps label — the popover's summary line.
struct HeroNumber: View {
    let title: String
    let value: Int
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(title)
            Text(value, format: .number)
                .font(Typography.hero)
                .tracking(Typography.heroTracking)
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint)
        }
        .animation(.snappy(duration: 0.25), value: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// The glass search pill in the window header and above the catalog.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    /// Shown in place of the clear button while a search is in flight.
    var loading: Bool = false
    /// A fixed width for the text field, for the header, where the pill is `fixedSize`d and the
    /// field would otherwise collapse to the prompt. Left nil the field fills what it is given.
    var fieldWidth: CGFloat?

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Typography.field)
                .frame(minWidth: fieldWidth.map { _ in 70 }, idealWidth: fieldWidth,
                       maxWidth: fieldWidth)
            if loading {
                ProgressView().controlSize(.mini)
            } else if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .pill()
    }
}

/// The "All clients / …" filter, in the popover header and the window header both.
struct ClientFilterMenu: View {
    let clients: [ClientStatus]
    @Binding var selection: ClientID?

    var body: some View {
        Menu {
            Button("All clients") { selection = nil }
            ForEach(clients) { client in
                Button(client.displayName) { selection = client.id }
            }
        } label: {
            Text(label).font(Typography.rowTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel("Client filter")
    }

    private var label: String {
        guard let selection else { return "All clients" }
        return clients.first { $0.id == selection }?.displayName ?? selection.rawValue
    }
}

/// The navigation strip: equal-width text segments inside a card-tier container. The active segment
/// takes the accent foreground over the accent tint; inactive ones recede rather than draw anything
/// of their own.
struct TabStrip<Value: Hashable>: View {
    private let options: [Value]
    private let title: (Value) -> String
    @Binding private var selection: Value

    @Environment(\.colorScheme) private var colorScheme

    init(_ options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let active = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.86))
                        // `maxWidth: .infinity` is what makes the segments equal inside a strip that
                        // has width to give — but under `fixedSize`, as in the main window's header,
                        // infinity resolves to the label's ideal width and the tint would end
                        // exactly where the word does. Hence the horizontal padding as well.
                        .padding(.horizontal, Space.card)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(active ? Surface.accentTint(colorScheme) : .clear,
                                    in: .rect(cornerRadius: Radius.row, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(Space.xs)
        .background(Surface.card, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Surface.hairline, lineWidth: Stroke.hairline)
        }
        .animation(.snappy(duration: 0.15), value: selection)
    }
}
