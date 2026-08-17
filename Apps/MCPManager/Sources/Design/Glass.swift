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
    static let label = Font.system(size: 10, weight: .medium)
    static let labelTracking: CGFloat = 0.4
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}

extension View {
    /// A raised glass surface: popover cards, main-window server cards. `selected` brightens the
    /// border instead of swapping the material, so selection animates in place.
    func glassCard(cornerRadius: CGFloat = 16, selected: Bool = false) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.85 : 0), lineWidth: 1)
            }
            .animation(.snappy(duration: 0.2), value: selected)
    }

    /// Capsule glass for filter menus and chips.
    func pill() -> some View {
        glassEffect(.regular, in: .capsule)
    }
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
