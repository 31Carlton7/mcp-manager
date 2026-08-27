import AppKit
import SwiftUI

// The numbers and colours every surface draws from.
//
// Two invariants the rest of the app depends on. Depth is fill plus hairline, never a shadow: three
// tinted fill tiers plus a sub-pixel border. Hierarchy is weight at a constant size — the working
// range is 10–13 pt, and a title outranks a caption by being semibold rather than by being bigger.

/// `card` is a card's interior module; `m` is the gutter *between* cards.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let card: CGFloat = 10
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Chips and small buttons, rows, plates, cards and containers, the panel shell. Every rounded
/// rectangle in the app uses continuous ("squircle") corners.
enum Radius {
    static let chip: CGFloat = 7
    static let row: CGFloat = 8
    static let plate: CGFloat = 10
    static let card: CGFloat = 12
    static let shell: CGFloat = 18
}

enum Stroke {
    static let hairline: CGFloat = 0.7
    static let shell: CGFloat = 0.8
}

/// `Font` carries no tracking, so tracking travels beside its font rather than inside it.
enum Typography {
    static let hero = Font.system(size: 34, weight: .semibold)
    static let heroTracking: CGFloat = -0.7
    /// 10 pt semibold uppercased at +0.5, secondary: every section label in the app.
    static let label = Font.system(size: 10, weight: .semibold)
    static let labelTracking: CGFloat = 0.5
    static let rowTitle = Font.system(size: 12, weight: .semibold)
    static let rowCaption = Font.system(size: 10)
    /// Editable text and menu labels, where semibold would read as emphasis rather than as a row.
    static let field = Font.system(size: 12)
    /// The platform body size, for the few places carrying a sentence rather than a row.
    static let body = Font.system(size: 13)
    /// Numeric readouts and quiet actions. Pair with `.monospacedDigit()` wherever it can change.
    static let value = Font.system(size: 11, weight: .medium)
    static let listValue = Font.system(size: 10.5, weight: .medium)
    /// Technical values — paths, commands, ports, identifiers — as opposed to numbers that tick.
    static let mono = Font.system(size: 11, design: .monospaced)
    static let microBadge = Font.system(size: 9, weight: .bold)
    static let microBadgeTracking: CGFloat = 0.4
}

/// The three fill tiers and the hairline they share, each a tint over whatever is behind it. Note
/// the inversion in light: the shell and the card lighten while the control tier *darkens*, so an
/// inset control reads as a recess in both schemes.
enum Surface {
    static let base = scheme(light: .white, lightAlpha: 0.68, dark: .black, darkAlpha: 0.42)
    static let card = scheme(light: .white, lightAlpha: 0.38, dark: .white, darkAlpha: 0.075)
    static let control = scheme(light: .black, lightAlpha: 0.055, dark: .white, darkAlpha: 0.085)
    /// The one fill that sits *on* a control rather than in it — the plate under a segmented
    /// control's selected segment — so it lightens in both schemes instead of following the control
    /// tier's inversion.
    static let raised = scheme(light: .white, lightAlpha: 0.92, dark: .white, darkAlpha: 0.18)
    static let hairline = scheme(light: .black, lightAlpha: 0.09, dark: .white, darkAlpha: 0.11)

    /// Accent tints need more opacity in dark for the same perceived presence.
    static func accentTint(_ colorScheme: ColorScheme) -> Color {
        .accentColor.opacity(colorScheme == .dark ? 0.20 : 0.13)
    }
}

/// The dual-tone metric palette. The light column is hand-darkened — at least one channel at 0, a
/// dominant channel around 0.56–0.68 — because the system hues are tuned as fills and are too
/// bright to read as *text* on a light translucent card. The dark column is the system palette,
/// which is already tuned for dark surfaces.
enum Semantic {
    static let green = scheme(light: NSColor(srgbRed: 0.00, green: 0.44, blue: 0.18, alpha: 1), dark: .systemGreen)
    static let cyan = scheme(light: NSColor(srgbRed: 0.00, green: 0.43, blue: 0.54, alpha: 1), dark: .systemCyan)
    static let yellow = scheme(light: NSColor(srgbRed: 0.56, green: 0.36, blue: 0.00, alpha: 1), dark: .systemYellow)
    /// Not part of the health ladder (green / yellow / red): prerelease, and the daemon's own
    /// quiet failures.
    static let orange = scheme(light: NSColor(srgbRed: 0.68, green: 0.30, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let red = scheme(light: NSColor(srgbRed: 0.68, green: 0.08, blue: 0.10, alpha: 1), dark: .systemRed)
}

private func scheme(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func scheme(light: NSColor, lightAlpha: CGFloat, dark: NSColor, darkAlpha: CGFloat) -> Color {
    scheme(light: light.withAlphaComponent(lightAlpha), dark: dark.withAlphaComponent(darkAlpha))
}
