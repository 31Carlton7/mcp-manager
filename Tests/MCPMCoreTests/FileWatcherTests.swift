import Testing
import Foundation
@testable import MCPMCore

@Test func watcherFiresOnceForBurstOfWritesAndOnAtomicRename() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-w-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("mcp.json")
    try Data("a".utf8).write(to: file)

    let watcher = FileWatcher(paths: [.cursor: file], debounce: .milliseconds(200))
    let stream = watcher.start()
    let collector = Task { () -> [ClientID] in
        var events: [ClientID] = []
        for await c in stream {
            events.append(c)
            if events.count == 2 { break }
        }
        return events
    }

    try await Task.sleep(for: .milliseconds(100))
    for i in 0..<5 { try Data("b\(i)".utf8).write(to: file) }          // burst → 1 event
    try await Task.sleep(for: .milliseconds(500))
    try Data("c".utf8).write(to: file, options: .atomic)               // rename-in-place → 1 event
    try await Task.sleep(for: .milliseconds(500))
    watcher.stop()
    let events = await collector.value
    #expect(events == [.cursor, .cursor])
}
