import SwiftUI

// The shared vocabulary for both surfaces: the popover and the main window. Everything here is
// deliberately small — a token, a modifier, or a view that is only layout and type — so a screen
// reads as composition rather than a pile of one-off numbers.

/// The only spacing values the UI is allowed to use.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Type ramp. `Font` has no notion of tracking, so the hero's negative tracking travels alongside
/// its font rather than inside it.
enum Typography {
    static let hero = Font.system(size: 34, weight: .semibold)
    /// −2% of 34 pt, the tightening the design calls for on the big numbers.
    static let heroTracking: CGFloat = -0.7
    static let label = Font.system(size: 11, weight: .medium)
    static let labelTracking: CGFloat = 0.4
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}

extension View {
    /// A raised card surface: server cards, the Add sheet's paste well.
    ///
    /// Spec adjustment: the design called for `glassEffect` here too. Glass samples and refracts
    /// whatever is behind it every frame, and the grid scrolls dozens of these at once — that is a
    /// real cost on a scroll, and the HIG reserves glass for the controls floating *above* content
    /// rather than for the content itself. So cards are a material, and true glass stays on the
    /// header pills and buttons and on the popover. Only the border changes with state, so
    /// selection and hover animate in place instead of swapping the surface out.
    func cardSurface(cornerRadius: CGFloat = 16, selected: Bool = false,
                     hovering: Bool = false) -> some View {
        background(.regularMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cardBorder(selected: selected, hovering: hovering), lineWidth: 1)
            }
            .animation(.snappy(duration: 0.18), value: selected)
            .animation(.snappy(duration: 0.18), value: hovering)
    }

    /// Capsule glass for filter menus and chips.
    func pill() -> some View {
        glassEffect(.regular, in: .capsule)
    }
}

/// Resting edge is just enough to separate a card from the window; hover lifts it, and selection
/// replaces it with the accent so the two never fight for the same pixel.
private func cardBorder(selected: Bool, hovering: Bool) -> Color {
    if selected { return .accentColor.opacity(hovering ? 1 : 0.85) }
    return .primary.opacity(hovering ? 0.18 : 0.07)
}

/// Press feedback for the small pressable things — chips, mostly, where `.plain` gives none. The
/// scale is skipped under Reduce Motion; the dimming still confirms the press.
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

/// One-pixel rule between sections. Thin enough to read as a seam rather than a border.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A big number under a small caps label — the popover's summary line.
struct HeroNumber: View {
    let title: String
    let value: Int
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(Typography.label)
                .tracking(Typography.labelTracking)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

/// Text labels used as tabs: the selected one is primary, the rest recede. No chrome, because the
/// hairline above them is already doing the dividing.
struct TextTabs<Value: Hashable>: View {
    private let options: [Value]
    private let title: (Value) -> String
    @Binding private var selection: Value

    init(_ options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(option == selection ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.15), value: selection)
    }
}

extension TextTabs where Value == String {
    init(_ options: [String], selection: Binding<String>) {
        self.init(options, selection: selection, title: { $0 })
    }
}
