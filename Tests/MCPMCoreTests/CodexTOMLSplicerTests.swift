import Testing
import Foundation
@testable import MCPMCore

private typealias S = CodexTOMLSplicer

@Test(arguments: [
    ("command = \"x\"", "command"),
    ("  args = []", "args"),
    ("env.A = \"1\"", "env"),                       // dotted keys count as their first segment
    ("http_headers . X = \"y\"", "http_headers"),
    ("\"command\" = \"x\"", "command"),
    ("'command' = \"x\"", "command"),
    ("startup_timeout_sec = 120", "startup_timeout_sec"),
])
func splicerReadsTopLevelKeys(line: String, key: String) {
    #expect(S.topLevelKey(of: line) == key)
}

@Test(arguments: ["", "   ", "# command = \"x\"", "[mcp_servers.x]", "no equals here", "= 1"])
func splicerIgnoresNonAssignments(line: String) {
    #expect(S.topLevelKey(of: line) == nil)
}

@Test(arguments: [
    ("[mcp_servers]", S.Header.root),
    ("[mcp_servers.x]", .server(name: "x", subPath: [])),
    ("[ mcp_servers.x ]", .server(name: "x", subPath: [])),
    ("[mcp_servers.x.env]", .server(name: "x", subPath: ["env"])),
    ("[mcp_servers.\"a b\".env]", .server(name: "a b", subPath: ["env"])),
    ("[mcp_servers.\"x]y\"]", .server(name: "x]y", subPath: [])),
    ("[mcp_servers.x] # trailing ] comment", .server(name: "x", subPath: [])),
    ("[projects.\"/Users/me/proj\"]", .other),
    ("[shell_environment_policy.set]", .other),
])
private func splicerParsesHeaders(line: String, header: S.Header) {
    #expect(S.parseHeader(line) == header)
}

@Test(arguments: ["command = \"x\"", "", "  # [mcp_servers.x]", "args = [\"a\"]"])
private func splicerRejectsNonHeaders(line: String) {
    #expect(S.parseHeader(line) == nil)
}

/// The scanner decides which lines are safe to interpret; a line is only a header or an
/// assignment when the state carried in from the previous line is clean.
@Test func splicerTracksOpenValuesAcrossLines() {
    var st = S.ScanState()
    #expect(S.scan("args = [\"a\",", from: st).isClean == false)
    st = S.scan("args = [\"a\",", from: st)
    st = S.scan("  \"b\",", from: st)
    #expect(st.isClean == false)
    st = S.scan("]", from: st)
    #expect(st.isClean)
}

@Test func splicerIgnoresBracketsInsideStrings() {
    #expect(S.scan("args = [\"a\", 'single ] quoted', \"b\"]", from: S.ScanState()).isClean)
    #expect(S.scan("command = \"a \\\" ] b\"", from: S.ScanState()).isClean)
    #expect(S.scan("cwd = \".\" # ] ] ]", from: S.ScanState()).isClean)
}

@Test func splicerTracksMultiLineStrings() {
    var st = S.scan("command = \"\"\"", from: S.ScanState())
    #expect(st.string == .multiBasic)
    st = S.scan("[mcp_servers.not_really_a_header]", from: st)          // still inside the string
    #expect(st.string == .multiBasic)
    st = S.scan("\"\"\"", from: st)
    #expect(st.isClean)

    var lit = S.scan("command = '''", from: S.ScanState())
    #expect(lit.string == .multiLiteral)
    lit = S.scan("'''", from: lit)
    #expect(lit.isClean)

    #expect(S.scan("command = \"\"\"one line\"\"\"", from: S.ScanState()).isClean)
}

@Test func splicerQuotesKeysThatCannotBeBare() {
    #expect(S.key("node_repl") == "node_repl")
    #expect(S.key("computer-use") == "computer-use")
    #expect(S.key("my server") == "\"my server\"")
    #expect(S.key("") == "\"\"")
    #expect(S.key("café") == "\"café\"")                                // non-ASCII letters are not bare keys
}

@Test func splicerEscapesControlCharacters() {
    #expect(S.str("a\"b\\c") == "\"a\\\"b\\\\c\"")
    #expect(S.str("a\r\nb\t") == "\"a\\r\\nb\\t\"")
    #expect(S.str("a\u{01}b\u{7F}") == "\"a\\u0001b\\u007F\"")
}

@Test func splicerDetectsLineTerminator() {
    #expect(S.terminator(of: "a\r\nb\r\n") == "\r\n")
    #expect(S.terminator(of: "a\nb\n") == "\n")
    #expect(S.terminator(of: "") == "\n")
    #expect(S.lines(of: "a\r\nb").count == 2)                           // CRLF is one Character in Swift
}
