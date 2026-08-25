import AppKit
import SwiftUI

// The measurement system every surface draws from. Nothing here renders anything on its own — it is
// the list of numbers and colours the views are allowed to reach for, so a screen reads as
// composition rather than as a pile of one-off values.
//
// Two ideas carry most of the weight. Depth is **fill plus hairline**, never a shadow: three tinted
// fill tiers separate the shell from cards from inset wells, and a sub-pixel border finishes each.
// Hierarchy is **weight at a constant size**: the working range is 10–13 pt, and a title outranks a
// caption by being semibold rather than by being bigger.

/// The only spacing values the UI is allowed to use. `card` is the module for a card's interior;
/// `m` is the gutter *between* cards. The 5× gap between "related" (1–4) and "unrelated" (10–12) is
/// what does the grouping work, in place of rules and boxes.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let card: CGFloat = 10
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Radii, read as a ladder: chips and small buttons, rows, plates, cards and containers, the panel
/// shell. Every rounded rectangle in the app uses continuous ("squircle") corners.
enum Radius {
    static let chip: CGFloat = 7
    static let row: CGFloat = 8
    static let plate: CGFloat = 10
    /// Grid and catalog cards. Deliberately 12 rather than the 10 of a dense row: our cards are
    /// larger objects at a 220 pt minimum and hold more, so the softer corner is proportionate.
    static let card: CGFloat = 12
    static let shell: CGFloat = 18
}

/// Sub-pixel at 2×, both of them, which is why they read as a seam rather than an outline.
enum Stroke {
    static let hairline: CGFloat = 0.7
    static let shell: CGFloat = 0.8
}

/// Type ramp. `Font` has no notion of tracking, so tracking travels alongside its font rather than
/// inside it. Sizes are few and weights do the ranking.
enum Typography {
    static let hero = Font.system(size: 34, weight: .semibold)
    /// −2% of 34 pt, the tightening large numerals want. Unrelated to `labelTracking`: positive
    /// tracking opens up small capitals, negative tracking closes up big figures.
    static let heroTracking: CGFloat = -0.7
    /// The signature gesture: 10 pt semibold, uppercased, +0.5, secondary. Every section label.
    static let label = Font.system(size: 10, weight: .semibold)
    static let labelTracking: CGFloat = 0.5
    static let rowTitle = Font.system(size: 12, weight: .semibold)
    static let rowCaption = Font.system(size: 10)
    /// Editable text and menu labels, where semibold would read as emphasis rather than as a row.
    static let field = Font.system(size: 12)
    /// The platform body size, kept for the handful of places that carry a sentence rather than a
    /// row. Everything dense lives at 10–12.
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    /// Numeric readouts and quiet actions. Pair with `.monospacedDigit()` wherever it can change.
    static let value = Font.system(size: 11, weight: .medium)
    static let listValue = Font.system(size: 10.5, weight: .medium)
    /// Technical values — paths, commands, ports, identifiers — as opposed to numbers that tick.
    static let mono = Font.system(size: 11, design: .monospaced)
    static let microBadge = Font.system(size: 9, weight: .bold)
    static let microBadgeTracking: CGFloat = 0.4
}

/// The three fill tiers, plus the hairline they all share. Note the inversion in light: the shell
/// and the card lighten, the control tier *darkens*, so an inset control reads as a recess in both
/// schemes. Every value is a tint over whatever is behind it — a material, a window, another card.
enum Surface {
    static let base = scheme(light: .white, lightAlpha: 0.68, dark: .black, darkAlpha: 0.42)
    static let card = scheme(light: .white, lightAlpha: 0.38, dark: .white, darkAlpha: 0.075)
    static let control = scheme(light: .black, lightAlpha: 0.055, dark: .white, darkAlpha: 0.085)
    static let hairline = scheme(light: .black, lightAlpha: 0.09, dark: .white, darkAlpha: 0.11)

    /// Accent tints need more opacity in dark for the same perceived presence.
    static func accentTint(_ colorScheme: ColorScheme) -> Color {
        .accentColor.opacity(colorScheme == .dark ? 0.20 : 0.13)
    }
}

/// The dual-tone metric palette: seven hues, each defined twice. The light column is hand-darkened
/// — at least one channel at 0, a dominant channel around 0.56–0.68 — because the system hues are
/// tuned as fills and are too bright to read as *text* on a light translucent card. The dark column
/// is simply the system palette, which is already tuned for dark surfaces.
enum Semantic {
    static let green = scheme(light: NSColor(srgbRed: 0.00, green: 0.44, blue: 0.18, alpha: 1), dark: .systemGreen)
    static let cyan = scheme(light: NSColor(srgbRed: 0.00, green: 0.43, blue: 0.54, alpha: 1), dark: .systemCyan)
    static let mint = scheme(light: NSColor(srgbRed: 0.00, green: 0.44, blue: 0.40, alpha: 1), dark: .systemMint)
    static let yellow = scheme(light: NSColor(srgbRed: 0.56, green: 0.36, blue: 0.00, alpha: 1), dark: .systemYellow)
    /// Reserved for experimental / prerelease and for the daemon's own quiet failures — not part of
    /// the health ladder, which is green / yellow / red.
    static let orange = scheme(light: NSColor(srgbRed: 0.68, green: 0.30, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let red = scheme(light: NSColor(srgbRed: 0.68, green: 0.08, blue: 0.10, alpha: 1), dark: .systemRed)
    static let pink = scheme(light: NSColor(srgbRed: 0.68, green: 0.06, blue: 0.34, alpha: 1), dark: .systemPink)
}

/// A colour that resolves itself against the window's appearance, so nothing downstream has to read
/// the colour scheme to pick between a light value and a dark one.
private func scheme(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func scheme(light: NSColor, lightAlpha: CGFloat, dark: NSColor, darkAlpha: CGFloat) -> Color {
    scheme(light: light.withAlphaComponent(lightAlpha), dark: dark.withAlphaComponent(darkAlpha))
}
