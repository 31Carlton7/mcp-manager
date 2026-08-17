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

@Test func watcherWaitsAtAnAncestorUntilTheConfigDirectoryAppears() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-w-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = root.appendingPathComponent("cursor")          // does not exist yet
    let file = dir.appendingPathComponent("mcp.json")

    let watcher = FileWatcher(paths: [.cursor: file], debounce: .milliseconds(100))
    let stream = watcher.start()
    #expect(watcher.unwatched().isEmpty)                      // standing in at `root`
    let collector = Task { () -> [ClientID] in
        var events: [ClientID] = []
        for await c in stream { events.append(c) }
        return events
    }

    try await Task.sleep(for: .milliseconds(100))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await Task.sleep(for: .milliseconds(200))
    try Data("a".utf8).write(to: file)
    try await Task.sleep(for: .milliseconds(500))
    watcher.stop()
    #expect(await collector.value == [.cursor])
}

@Test func watcherStartIsIdempotent() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-w-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("mcp.json")
    try Data("a".utf8).write(to: file)

    let watcher = FileWatcher(paths: [.cursor: file], debounce: .milliseconds(50))
    _ = watcher.start()
    _ = watcher.start()
    defer { watcher.stop() }
    #expect(watcher.sourceCount == 2)
}

@Test func watcherReArmsWithoutAccumulatingSources() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-w-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("mcp.json")

    let watcher = FileWatcher(paths: [.cursor: file], debounce: .milliseconds(50))
    _ = watcher.start()
    defer { watcher.stop() }

    // Every atomic replace swaps the inode, so the per-file source has to be re-armed each time.
    for i in 0..<4 {
        try Data("v\(i)".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(150))
    }
    #expect(watcher.sourceCount == 2)   // one directory source + one file source
}
