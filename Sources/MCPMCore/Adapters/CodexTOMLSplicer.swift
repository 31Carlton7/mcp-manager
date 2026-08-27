import Foundation

/// Line-level surgery on a Codex `config.toml`. TOMLKit reads the file; this writes it back,
/// touching only the `[mcp_servers.*]` region and leaving every other byte where it was.
///
/// Everything here works on raw lines, so it must reason about TOML's lexical shapes itself:
/// comments, basic/literal strings, multi-line strings, and values that span lines.
enum CodexTOMLSplicer {
    /// Keys under `[mcp_servers.<name>]` that `ExternalServer` owns, and therefore rewrites on edit.
    static let modeledKeys: Set<String> = ["command", "args", "env", "url", "http_headers"]

    // MARK: - Lines

    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// The terminator to write back with: CRLF if the file uses it anywhere, else LF.
    static func terminator(of text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    static func trimmed(_ lines: [String]) -> [String] {
        var l = lines
        while let last = l.last, last.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        while let first = l.first, first.trimmingCharacters(in: .whitespaces).isEmpty { l.removeFirst() }
        return l
    }

    // MARK: - Lexical state

    /// How much of a value is still open at the end of a line: bracket nesting plus multi-line strings.
    /// A line is only safe to interpret as a header or a `key = value` when the state before it is clean.
    struct ScanState: Equatable {
        enum StringKind: Equatable { case none, multiBasic, multiLiteral }
        var depth = 0
        var string = StringKind.none
        var isClean: Bool { depth == 0 && string == .none }
    }

    static func scan(_ line: String, from state: ScanState) -> ScanState {
        var s = state
        let c = Array(line)
        var i = 0
        while i < c.count {
            switch s.string {
            case .multiBasic:
                if c[i] == "\\" { i += 2 }                              // escape, incl. line-ending backslash
                else if c[i...].starts(with: "\"\"\"") { s.string = .none; i += 3 }
                else { i += 1 }
            case .multiLiteral:
                if c[i...].starts(with: "'''") { s.string = .none; i += 3 } else { i += 1 }
            case .none:
                if c[i] == "#" { return s }                             // comment runs to end of line
                if c[i...].starts(with: "\"\"\"") { s.string = .multiBasic; i += 3 }
                else if c[i...].starts(with: "'''") { s.string = .multiLiteral; i += 3 }
                else if c[i] == "\"" || c[i] == "'" { i = endOfSingleLineString(c, from: i) }
                else {
                    if c[i] == "[" || c[i] == "{" { s.depth += 1 }
                    else if c[i] == "]" || c[i] == "}" { s.depth = max(0, s.depth - 1) }
                    i += 1
                }
            }
        }
        return s
    }

    /// Index just past the closing quote of a single-line string opened at `i` (end of line if unterminated).
    private static func endOfSingleLineString(_ c: [Character], from i: Int) -> Int {
        let quote = c[i]
        var j = i + 1
        while j < c.count {
            if quote == "\"", c[j] == "\\" { j += 2; continue }          // literal strings have no escapes
            if c[j] == quote { return j + 1 }
            j += 1
        }
        return j
    }

    // MARK: - Headers and keys

    enum Header: Equatable {
        case root                                       // [mcp_servers]
        case server(name: String, subPath: [String])    // [mcp_servers.x] / [mcp_servers.x.env]
        case other                                      // a table header for something else
    }

    /// Parses a table header line. `nil` when the line is not a table header.
    /// Quote-aware, so `[mcp_servers."a.b]c"]` and `[ mcp_servers.x ]` both work.
    ///
    /// An array-of-tables header is `.other`: we never write one, and it must end the preceding
    /// block rather than be swallowed into it.
    static func parseHeader(_ line: String) -> Header? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        guard !t.hasPrefix("[[") else { return .other }
        guard let (inner, _) = bracketed(t) else { return nil }
        guard let segs = segments(inner), segs.first == "mcp_servers" else { return .other }
        if segs.count == 1 { return .root }
        return .server(name: segs[1], subPath: Array(segs.dropFirst(2)))
    }

    /// Whatever follows the closing `]` of a header, e.g. `[mcp_servers.x] # note` → " # note".
    /// `nil` when there is nothing to carry over.
    static func headerTrailer(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("[["), let (_, rest) = bracketed(t) else { return nil }
        let trailer = String(rest).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trailer.trimmingCharacters(in: .whitespaces).isEmpty ? nil : trailer
    }

    /// The key path inside a `[...]` header (quotes kept for `segments`) and the text after the `]`.
    private static func bracketed(_ t: String) -> (inner: String, rest: Substring)? {
        let body = t.dropFirst()
        var inner = ""
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c == "\"" || c == "'" {
                guard let end = body[body.index(after: i)...].firstIndex(of: c) else { return nil }
                inner += String(body[i...end])
                i = body.index(after: end)
            } else if c == "]" {
                return (inner, body[body.index(after: i)...])
            } else {
                inner.append(c)
                i = body.index(after: i)
            }
        }
        return nil
    }

    /// Splits a dotted key path into decoded segments; quoted segments keep their spacing.
    static func segments(_ s: String) -> [String]? {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" || c == "'" {
                guard let end = s[s.index(after: i)...].firstIndex(of: c) else { return nil }
                cur += String(s[s.index(after: i)..<end])
                quoted = true
                i = s.index(after: end)
            } else if c == "." {
                out.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces))
                cur = ""
                quoted = false
                i = s.index(after: i)
            } else {
                cur.append(c)
                i = s.index(after: i)
            }
        }
        out.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// The first segment of the key in a `key = value` line, e.g. `env.A = "1"` → "env".
    /// `nil` for comments, blanks, headers and anything that isn't an assignment.
    static func topLevelKey(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), !t.hasPrefix("["), let eq = t.firstIndex(of: "=") else { return nil }
        let k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
        guard let segs = segments(k), let first = segs.first, !first.isEmpty else { return nil }
        return first
    }

    // MARK: - Splitting a file into the mcp_servers region and everything else

    struct Split {
        /// Every line outside `[mcp_servers.*]`, in order.
        var other: [String] = []
        /// Server names in the order their blocks appear.
        var order: [String] = []
        /// All lines belonging to a server, main table and sub-tables concatenated.
        var blocks: [String: [String]] = [:]
    }

    /// Lines under a bare `[mcp_servers]` header belong to no named block; they are regenerated,
    /// not preserved, so the header cannot survive into the output as an empty table.
    static func split(_ text: String) -> Split {
        var result = Split()
        var current: (name: String?, lines: [String])?
        var state = ScanState()

        func flush() {
            guard let c = current else { return }
            current = nil
            guard let name = c.name else { return }
            if result.blocks[name] == nil { result.order.append(name) }
            result.blocks[name, default: []] += c.lines
        }

        for line in lines(of: text) {
            let clean = state.isClean
            state = scan(line, from: state)
            guard clean else {                                          // continuation of an open value
                if current != nil { current!.lines.append(line) } else { result.other.append(line) }
                continue
            }
            switch parseHeader(line) {
            case .server(let name, _):
                if current?.name != name { flush() }
                if current == nil { current = (name, [line]) } else { current!.lines.append(line) }
            case .root:
                flush()
                current = (nil, [line])
            case .other:
                flush()
                result.other.append(line)
            case nil:
                if current != nil { current!.lines.append(line) } else { result.other.append(line) }
            }
        }
        flush()
        return result
    }

    // MARK: - Preserving what we don't model

    /// Everything in an old block that `ExternalServer` cannot express: key lines of the main table
    /// (minus `modeledKeys`, including dotted forms like `env.A`) and whole sub-tables we don't rewrite.
    static func preserved(_ lines: [String]) -> (keys: [String], subTables: [String]) {
        enum Region { case main, drop, keep }
        var region = Region.main
        var keys: [String] = []
        var subTables: [String] = []
        var dropping = false
        var state = ScanState()

        for line in lines {
            let clean = state.isClean
            state = scan(line, from: state)
            guard clean else {                                          // continuation of an open value
                if dropping {
                    dropping = !state.isClean
                } else {
                    switch region {
                    case .main: keys.append(line)
                    case .drop: ()
                    case .keep: subTables.append(line)
                    }
                }
                continue
            }
            dropping = false
            if case .server(_, let sub)? = parseHeader(line) {
                if sub.isEmpty {
                    region = .main                                      // the block header itself
                } else if let head = sub.first, modeledKeys.contains(head) {
                    region = .drop                                      // we rewrite env / http_headers whole
                } else {
                    region = .keep
                    subTables.append(line)
                }
                continue
            }
            if region == .main, let k = topLevelKey(of: line), modeledKeys.contains(k) {
                dropping = !state.isClean                               // swallow multi-line values whole
                continue
            }
            switch region {
            case .main: keys.append(line)
            case .drop: ()
            case .keep: subTables.append(line)
            }
        }
        return (trimmed(keys), trimmed(subTables))
    }

    // MARK: - Emitting

    /// A bare key if TOML allows it (ASCII letters, digits, `_`, `-`), otherwise a quoted one.
    static func key(_ k: String) -> String {
        let bare = !k.isEmpty && k.allSatisfy { c in
            c == "_" || c == "-" || (c.isASCII && (c.isLetter || c.isNumber))
        }
        return bare ? k : str(k)
    }

    static func str(_ v: String) -> String {
        var o = "\""
        for c in v.unicodeScalars {
            switch c {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if c.value < 0x20 || c.value == 0x7F {
                    o += String(format: "\\u%04X", c.value)
                } else {
                    o.unicodeScalars.append(c)
                }
            }
        }
        return o + "\""
    }
}
