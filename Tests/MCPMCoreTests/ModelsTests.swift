import Testing
@testable import MCPMCore

@Test func clientIDsAreStableStrings() {
    #expect(ClientID.claudeCode.rawValue == "claude-code")
    #expect(ClientID.claudeDesktop.rawValue == "claude-desktop")
    #expect(ClientID.cursor.rawValue == "cursor")
    #expect(ClientID.codex.rawValue == "codex")
    #expect(ClientID.allCases.count == 4)
}
