public enum AllAdapters {
    public static func make() -> [any ClientAdapter] {
        [ClaudeCodeAdapter(), ClaudeDesktopAdapter(), CursorAdapter(), CodexAdapter()]
    }
}
