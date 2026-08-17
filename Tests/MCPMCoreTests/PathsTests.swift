import Testing
import Foundation
@testable import MCPMCore

@Test func homeDirectoryFollowsTheHOMEEnvironment() throws {
    let original = ProcessInfo.processInfo.environment["HOME"]
    defer {
        if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
    }

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcpm-home-\(UUID().uuidString)").path
    setenv("HOME", scratch, 1)

    // Without this, a daemon started against a scratch home would still find the real one:
    // homeDirectoryForCurrentUser reads the password database and ignores $HOME.
    #expect(HomeDirectory.url.path == scratch)
    #expect(Paths().root.path == scratch + "/.mcpm")
    #expect(CursorAdapter().configPath.path == scratch + "/.cursor/mcp.json")
}
