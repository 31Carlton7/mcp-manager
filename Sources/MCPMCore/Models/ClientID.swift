public enum ClientID: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case cursor
    case codex

    public static func < (a: ClientID, b: ClientID) -> Bool { a.rawValue < b.rawValue }
}
