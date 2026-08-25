import SwiftUI
import MCPMControl

/// The daemon's `ServerStatus.state` string, as the UI reads it. The wire type is a `String` so a
/// state added by a newer daemon doesn't break the decode — which leaves exactly one place, here,
/// that has to decide what an unrecognised state looks like: `none`, the quiet one.
enum AuthStatus: String {
    case none, needsAuth, connected, expiring, error

    init(_ raw: String) { self = AuthStatus(rawValue: raw) ?? .none }

    /// Yellow is "you can fix this", red is "something went wrong", grey is "nothing to say".
    /// The hues come from the dual-tone palette, which is what lets them work as coloured *text* on
    /// a light translucent card as well as as a dot on a dark one.
    var color: Color {
        switch self {
        case .connected: Semantic.green
        case .needsAuth, .expiring: Semantic.yellow
        case .error: Semantic.red
        case .none: .secondary
        }
    }

    var label: String {
        switch self {
        case .none: "No auth"
        case .needsAuth: "Needs sign-in"
        case .connected: "Connected"
        case .expiring: "Expiring — will refresh"
        case .error: "Sign-in error"
        }
    }

    /// What the popover's hero number counts: a sign-in the user has to do, or a failure only they
    /// can clear. An expiring token refreshes itself, so it isn't anybody's chore.
    var needsAttention: Bool { self == .needsAuth || self == .error }
}

extension ServerStatus {
    var authStatus: AuthStatus { AuthStatus(state) }
}
