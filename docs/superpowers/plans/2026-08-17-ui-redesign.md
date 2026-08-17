# MCP Manager — Plan 1.5: UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every task touching `Apps/MCPManager` MUST first invoke the `caikins-swiftui` skill (macOS 26 / Liquid Glass APIs).

**Goal:** Replace the skeleton UI with a Liquid Glass popover (pill filter, hero numbers, icon rows), a main window with a card grid + right inspector, and a smart-paste Add sheet with advanced fields hidden.

**Architecture:** App-only change on top of the existing `DaemonClient` (status stream, optimistic toggles, ordered commands). Two small pure helpers land in `MCPMCore` so they are unit-testable: `SmartPasteParser` (URL / command line / README JSON → `[ExternalServer]`) and `IconSource` (server → bundled symbol / favicon host / monogram). Icons are resolved app-side with a disk cache. No daemon or protocol changes.

**Tech Stack:** Swift 6.2, SwiftUI on macOS 26 (`glassEffect`, `GlassEffectContainer`, `.inspector`, `LazyVGrid`, `MenuBarExtra(.window)`), XcodeGen, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-17-ui-redesign-design.md`

---

## File structure

```
Sources/MCPMCore/Import/SmartPasteParser.swift     pure: text → [ExternalServer] + detection summary
Sources/MCPMCore/Icons/IconSource.swift            pure: Server → IconSource enum
Tests/MCPMCoreTests/SmartPasteParserTests.swift
Tests/MCPMCoreTests/IconSourceTests.swift
Apps/MCPManager/Sources/
  Design/Glass.swift            glass card / pill / hairline modifiers, spacing + type tokens
  Design/ServerIcon.swift       ServerIcon view + FaviconCache (actor)
  DaemonClient.swift            + derived helpers: filtered servers, counts, lastSynced
  MenuBarView.swift             rewritten (popover)
  MainWindow/MainWindowView.swift      header + grid + inspector container
  MainWindow/ServerCard.swift
  MainWindow/InspectorView.swift
  MainWindow/AddServerSheet.swift      smart paste
  MCPManagerApp.swift           window style + min size
```

---

### Task 1: SmartPasteParser (MCPMCore)

**Files:** Create `Sources/MCPMCore/Import/SmartPasteParser.swift`, `Tests/MCPMCoreTests/SmartPasteParserTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import MCPMCore

@Test func parsesBareURLAsRemote() throws {
    let r = SmartPasteParser.parse("  https://mcp.notion.com/mcp \n")
    #expect(r.servers == [ExternalServer(name: "notion", kind: .remote, url: "https://mcp.notion.com/mcp")])
    #expect(r.summary == "Remote server · mcp.notion.com")
}

@Test func parsesCommandLineWithQuotes() throws {
    let r = SmartPasteParser.parse(#"npx -y @playwright/mcp@latest --browser "chrome canary""#)
    #expect(r.servers == [ExternalServer(name: "playwright-mcp", kind: .stdio, command: "npx", args: ["-y", "@playwright/mcp@latest", "--browser", "chrome canary"])])
    #expect(r.summary == "Local server · npx")
}

@Test func nameFromCommandBasenameWhenNoPackage() {
    let r = SmartPasteParser.parse("/usr/local/bin/my-server --port 3")
    #expect(r.servers.first?.name == "my-server")
}

@Test func parsesReadmeJSONWithMcpServersWrapper() throws {
    let json = #"{"mcpServers":{"context7":{"url":"https://mcp.context7.com/mcp"},"fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],"env":{"A":"1"}}}}"#
    let r = SmartPasteParser.parse(json)
    #expect(Set(r.servers.map(\.name)) == ["context7", "fs"])
    #expect(r.summary == "2 servers from JSON")
}

@Test func parsesNameMapAndBareObject() {
    #expect(SmartPasteParser.parse(#"{"exa":{"url":"https://mcp.exa.ai/mcp","headers":{"X":"1"}}}"#).servers ==
            [ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["X": "1"])])
    let bare = SmartPasteParser.parse(#"{"command":"uvx","args":["mcp-server-fetch"]}"#)
    #expect(bare.servers == [ExternalServer(name: "mcp-server-fetch", kind: .stdio, command: "uvx", args: ["mcp-server-fetch"])])
}

@Test func emptyAndGarbageYieldNothing() {
    #expect(SmartPasteParser.parse("").servers.isEmpty)
    #expect(SmartPasteParser.parse("{not json").servers.isEmpty)
    #expect(SmartPasteParser.parse("{not json").summary == "Couldn't parse that JSON")
    #expect(SmartPasteParser.parse("   ").summary == "")
}
```

- [ ] **Step 2: Run** `swift test --filter SmartPasteParserTests` → compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Turns whatever a user pastes (URL, command line, README JSON) into servers.
public enum SmartPasteParser {
    public struct Result: Equatable, Sendable {
        public var servers: [ExternalServer]
        /// One-line human description of what was detected ("" for empty input).
        public var summary: String
    }

    public static func parse(_ raw: String) -> Result {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return Result(servers: [], summary: "") }
        if text.hasPrefix("{") || text.hasPrefix("[") { return parseJSON(text) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host {
            return Result(servers: [ExternalServer(name: nameFromHost(host), kind: .remote, url: text)],
                          summary: "Remote server · \(host)")
        }
        let tokens = shellSplit(text)
        guard let command = tokens.first, !command.isEmpty else { return Result(servers: [], summary: "") }
        let args = Array(tokens.dropFirst())
        return Result(servers: [ExternalServer(name: nameFromCommand(command, args: args), kind: .stdio, command: command, args: args)],
                      summary: "Local server · \((command as NSString).lastPathComponent)")
    }

    // MARK: JSON

    static func parseJSON(_ text: String) -> Result {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return Result(servers: [], summary: "Couldn't parse that JSON")
        }
        var servers: [ExternalServer] = []
        if let section = obj["mcpServers"] as? [String: Any] {
            servers = section.compactMap { k, v in (v as? [String: Any]).flatMap { JSONMCPServers.external(name: k, dict: $0) } }
        } else if let one = JSONMCPServers.external(name: "", dict: obj) {
            // bare server object → derive a name
            let name = one.kind == .remote ? nameFromHost(URL(string: one.url ?? "")?.host ?? "server")
                                           : nameFromCommand(one.command ?? "server", args: one.args)
            servers = [ExternalServer(name: name, kind: one.kind, command: one.command, args: one.args, env: one.env, url: one.url, headers: one.headers)]
        } else {
            servers = obj.compactMap { k, v in (v as? [String: Any]).flatMap { JSONMCPServers.external(name: k, dict: $0) } }
        }
        servers.sort { $0.name < $1.name }
        let summary = servers.isEmpty ? "No servers found in that JSON"
                    : servers.count == 1 ? (servers[0].kind == .remote ? "Remote server · \(URL(string: servers[0].url ?? "")?.host ?? "")" : "Local server · \(servers[0].command ?? "")")
                    : "\(servers.count) servers from JSON"
        return Result(servers: servers, summary: summary)
    }

    // MARK: naming

    static func nameFromHost(_ host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        if parts.first == "www" || parts.first == "mcp" || parts.first == "api" { parts.removeFirst() }
        if parts.count >= 2 { parts.removeLast() }           // drop TLD
        return parts.first ?? host
    }

    /// `npx -y @scope/pkg@ver` → "pkg"; `uvx mcp-server-fetch` → "mcp-server-fetch"; else command basename.
    static func nameFromCommand(_ command: String, args: [String]) -> String {
        let base = (command as NSString).lastPathComponent
        if ["npx", "uvx", "pipx", "bunx", "pnpx"].contains(base) {
            if let pkg = args.first(where: { !$0.hasPrefix("-") && $0 != "run" }) {
                var p = pkg
                if p.hasPrefix("@"), let slash = p.firstIndex(of: "/") { p = String(p[p.index(after: slash)...]) }
                if let at = p.firstIndex(of: "@") { p = String(p[..<at]) }
                return p.isEmpty ? base : p
            }
        }
        return base
    }

    /// Minimal POSIX-ish splitter: whitespace separated, honours "double" and 'single' quotes and backslash escapes.
    static func shellSplit(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inS = false, inD = false, esc = false, has = false
        for ch in s {
            if esc { cur.append(ch); esc = false; continue }
            switch ch {
            case "\\" where !inS: esc = true
            case "'" where !inD: inS.toggle(); has = true
            case "\"" where !inS: inD.toggle(); has = true
            case " ", "\t", "\n" where !inS && !inD:
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            default: cur.append(ch); has = true
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}
```
Note: `JSONMCPServers.external(name:dict:)` is currently `static` (internal) — it's in the same module, fine.

- [ ] **Step 4: Run** → 6 pass; full suite green. **Step 5: Commit** `feat(core): SmartPasteParser for URL / command / README JSON`.

---

### Task 2: IconSource (MCPMCore) + ServerIcon view & FaviconCache (app)

**Files:** Create `Sources/MCPMCore/Icons/IconSource.swift`, `Tests/MCPMCoreTests/IconSourceTests.swift`, `Apps/MCPManager/Sources/Design/ServerIcon.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import MCPMCore

@Test func knownSlugsMapToSymbols() {
    #expect(IconSource.resolve(name: "GitHub", kind: .remote, url: "https://api.githubcopilot.com/mcp", command: nil) == .favicon(host: "api.githubcopilot.com"))
    #expect(IconSource.resolve(name: "filesystem", kind: .stdio, url: nil, command: "npx") == .symbol("folder"))
    #expect(IconSource.resolve(name: "Playwright", kind: .stdio, url: nil, command: "npx") == .symbol("theatermasks"))
}
@Test func remoteWithoutKnownSymbolUsesFavicon() {
    #expect(IconSource.resolve(name: "Anything", kind: .remote, url: "https://mcp.example.com/mcp", command: nil) == .favicon(host: "mcp.example.com"))
}
@Test func localhostRemoteAndStdioFallBackToMonogram() {
    #expect(IconSource.resolve(name: "Figma Desktop", kind: .remote, url: "http://127.0.0.1:3845/mcp", command: nil) == .monogram("FD", hue: IconSource.hue("Figma Desktop")))
    #expect(IconSource.resolve(name: "nia", kind: .stdio, url: nil, command: "pipx") == .monogram("N", hue: IconSource.hue("nia")))
}
@Test func monogramRules() {
    #expect(IconSource.monogram(for: "context7") == "C")
    #expect(IconSource.monogram(for: "node_repl") == "NR")
    #expect(IconSource.monogram(for: "computer-use") == "CU")
    #expect(IconSource.hue("nia") == IconSource.hue("nia"))
    #expect((0..<360).contains(IconSource.hue("anything")))
}
```

- [ ] **Step 2: Run** → compile error. **Step 3: Implement**

```swift
import Foundation

public enum IconSource: Equatable, Sendable {
    case symbol(String)               // SF Symbol name
    case favicon(host: String)        // fetch https://host/favicon.ico (app-side)
    case monogram(String, hue: Int)   // 1–2 letters + background hue 0..<360

    /// Generic, kind-agnostic symbols for well-known reference servers (brand marks come from favicons).
    static let symbols: [String: String] = [
        "filesystem": "folder", "fetch": "arrow.down.doc", "memory": "brain", "playwright": "theatermasks",
        "puppeteer": "theatermasks", "postgres": "cylinder", "sqlite": "cylinder", "git": "arrow.triangle.branch",
        "time": "clock", "sequential-thinking": "list.number", "everything": "sparkles",
    ]

    public static func resolve(name: String, kind: ServerKind, url: String?, command: String?) -> IconSource {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "-")
        if let s = symbols.first(where: { key.contains($0.key) })?.value { return .symbol(s) }
        if kind == .remote, let u = URL(string: url ?? ""), let host = u.host?.lowercased(),
           !(host == "localhost" || host.hasPrefix("127.") || host.hasSuffix(".local")) {
            return .favicon(host: host)
        }
        return .monogram(monogram(for: name), hue: hue(name))
    }

    public static func monogram(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }).filter { !$0.isEmpty }
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]).uppercased() }
        return String(name.first.map { String($0) } ?? "?").uppercased()
    }

    public static func hue(_ name: String) -> Int {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 360)
    }
}
```

`Apps/MCPManager/Sources/Design/ServerIcon.swift` (implementer writes; requirements):
- `struct ServerIcon: View { let server: Server; var size: CGFloat = 26 }` — renders per `IconSource.resolve(...)`: `.symbol` → `Image(systemName:)` on a tinted rounded rect; `.monogram` → text on `Color(hue: hue/360, saturation: 0.55, brightness: 0.75)`; `.favicon` → monogram immediately, then `.task(id: host)` asks `FaviconCache.shared.image(for: host)` and cross-fades the `NSImage` in.
- `actor FaviconCache` — memory dict + disk cache at `FileManager.default.urls(for: .cachesDirectory…)/co.charmtechnologies.mcpmanager/icons/<host>.png`; tries `https://<host>/favicon.ico` then `https://www.google.com/s2/favicons?domain=<host>&sz=64`; 8 s timeout; failures cached as "none" for the session; never throws to the view.
- Rounded corner radius = size * 0.27; `.accessibilityHidden(true)`.

- [ ] **Step 4:** `swift test` green; app builds. **Step 5: Commit** `feat: IconSource + ServerIcon with favicon cache`.

---

### Task 3: Design tokens + Glass helpers + popover redesign

**Files:** Create `Apps/MCPManager/Sources/Design/Glass.swift`; rewrite `Apps/MCPManager/Sources/MenuBarView.swift`; extend `DaemonClient.swift` with derived helpers.

- [ ] **Step 1 (skill):** invoke `caikins-swiftui`; use `glassEffect(_:in:)`, `GlassEffectContainer`, `.buttonStyle(.glass)` where available on macOS 26; otherwise `.regularMaterial` fallbacks behind `if #available`.

- [ ] **Step 2: Glass.swift** — tokens: `enum Space { static let xs=4, s=8, m=12, l=16, xl=20 }`; `enum Type { hero = .system(size: 34, weight: .semibold) with .tracking(-0.7); label = .system(size: 11) uppercase secondary; body 13; caption 11 }`; view modifiers: `.glassCard(cornerRadius: 16, selected: Bool)`, `.pill()` (capsule glass), `Hairline()` (1 pt `.separator` opacity 0.5), `HeroNumber(title:value:tint:)`, `TextTabs(["Servers","Clients"], selection:)`.

- [ ] **Step 3: DaemonClient derived helpers** (all `@MainActor` computed on `status`):
```swift
var installedClients: [ClientStatus]          // status.clients.filter(\.installed)
func servers(filter: ClientID?) -> [ServerStatus]   // nil = all; else enabled-in-that-client OR all? → ALL servers, but toggle acts on that client
func activeCount(filter: ClientID?) -> Int    // enabled in ≥1 installed client (or in `filter`)
var attentionCount: Int                       // servers with state == "needsAuth" + unhealthy installed clients
var lastSynced: Date?                         // max lastSync across installed clients
```

- [ ] **Step 4: MenuBarView** per spec §2.1. Structure:
```
VStack(spacing: Space.m) {
  header: HStack { Menu(filterLabel) { All clients / each installed } .menuStyle(.button).pill();  Spacer(); Button(open) { Image(systemName:"gearshape") }.buttonStyle(.glass) }
  heroes: HStack(spacing: 28) { HeroNumber("Active", active, .primary); HeroNumber("Clients", n, .primary); HeroNumber("Needs attention", k, k>0 ? .yellow : .secondary) }
  Hairline()
  TextTabs(selection: $tab)
  ScrollView { LazyVStack(spacing: 2) { rows } }.frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
  errors (red / orange captions)
  Hairline()
  footer: HStack { Text("Synced \(time)").caption.secondary; Spacer(); Button("Open MCP Manager ↗").buttonStyle(.plain).caption }
}.padding(Space.l).frame(width: 330)
```
Server row: `ServerIcon(size: 26)`, name, optional yellow "Sign in" pill when `state == "needsAuth"`, `Spacer`, `Toggle(.switch).controlSize(.mini)` bound through the optimistic overlay (`filter == nil ? setAll : setClient(filter)`).
Clients tab row: name · dot (green/red by `healthy`) · "\(n) servers" · `Button("Re-import")`.
Disconnected: heroes `.opacity(0.4)`, header replaced by "Background service unreachable" (reason in `.help`).
Quit lives in the ⚙︎ button's menu (Open MCP Manager… / Quit MCP Manager) — keep the "service keeps running" help.

- [ ] **Step 5:** build succeeds; run against the live daemon (it's running against the real home; do NOT restart it) and eyeball. **Commit** `feat(app): glass popover with hero numbers`.

---

### Task 4: Main window — grid + filters + search + inspector

**Files:** Create `Apps/MCPManager/Sources/MainWindow/{MainWindowView,ServerCard,InspectorView}.swift`; delete `ServersView.swift`; update `MCPManagerApp.swift`.

- [ ] **Step 1 (skill):** invoke `caikins-swiftui`.
- [ ] **Step 2: MCPManagerApp** — `Window("MCP Manager", id: "main") { MainWindowView() }.windowStyle(.hiddenTitleBar).defaultSize(width: 900, height: 560)`; content `.containerBackground(.thinMaterial, for: .window)` (or Tahoe glass equivalent per skill); min size 820×520.
- [ ] **Step 3: MainWindowView** — `@State selection: String?`, `clientFilter: ClientID?`, `kindFilter: ServerKind?`, `query: String`, `showAdd`. Layout: `VStack { headerRow; ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) { ForEach(filtered) { ServerCard(...) .onTapGesture { selection = id } } } .padding } }.inspector(isPresented: .constant(true)) { InspectorView(serverID: selection) }.inspectorColumnWidth(min: 250, ideal: 280, max: 320)`. Header row: client pill `Menu`, kind pill `Menu`, `Spacer`, search `TextField` styled `.pill()` with magnifier (or `.searchable`), `Button("Add", systemImage: "plus").buttonStyle(.borderedProminent)`. Filtering: name contains query (case-insensitive) AND kind match AND (clientFilter == nil || enabled in that client). Keyboard: `.onDeleteCommand` → confirmation → `daemon.remove`. Disconnected banner as today (reuse the pattern).
- [ ] **Step 4: ServerCard** — `.glassCard(selected:)`; top `HStack { ServerIcon(26); VStack(alignment: .leading) { name .semibold; subline .caption .secondary } }`; subline = `"\(kind) · \(remote ? host : command)"` or yellow "needs sign-in"; bottom `HStack(spacing:4) { ForEach(installedClients) { chip(client.displayName, on: enabled) } }` — chips are **buttons** that toggle that client (optimistic). Fixed height ~96.
- [ ] **Step 5: InspectorView** — if no selection: `ContentUnavailableView("Select a server", systemImage: "square.grid.2x2")`. Else: header (`ServerIcon(34)`, name 14 semibold, subline host/command); section **Enabled in** (`Toggle(.switch)` per installed client, optimistic); **Connection** (monospace URL or `command args…`, and "OAuth · connected" / "No auth" line); **Advanced** `DisclosureGroup`: for stdio → editable Args (`TextField` space-joined) + Env (list of key/value `TextField` pairs with +/−); for remote → Headers **read-only** list with caption "Header editing arrives with the auth gateway"; edits commit on submit via `daemon.update(UpdateServerParams…)` (add `func update(_ p: UpdateServerParams)` to `DaemonClient` — sends `.updateServer`); footer `HStack { Button("Test").disabled(true).help("Available in a later version"); Spacer(); Button("Remove", role: .destructive) → confirmation }`.
- [ ] **Step 6:** build; eyeball with live daemon; **Commit** `feat(app): card grid with inspector`.

---

### Task 5: Add sheet with smart paste

**Files:** Create `Apps/MCPManager/Sources/MainWindow/AddServerSheet.swift` (replace the old struct).

- [ ] **Step 1:** `@State paste = ""`, `parsed = SmartPasteParser.Result(servers: [], summary: "")`, `name = ""`, `clients: Set<ClientID>` (default all installed), `advanced = false`, `argsText`, `env: [(String,String)]`, `headers: [(String,String)]`. `.onChange(of: paste)` → `parsed = SmartPasteParser.parse(paste)`; when exactly one server parsed and `name` untouched → `name = server.name`; args/env/headers seed the advanced fields.
- [ ] **Step 2:** UI per spec §2.3: title "Add MCP server"; `TextEditor` (min height 52, monospaced 12, placeholder overlay) in a glass field; summary caption (secondary; red if summary starts with "Couldn't"/"No servers"); `Hairline`; `LabeledContent("Name") { TextField }` (only when 1 server); `LabeledContent("Enable in") { chips toggling membership }`; `DisclosureGroup("Advanced", isExpanded: $advanced)` { Args, Env, Headers (remote), Auth `Picker` disabled with caption }; buttons Cancel / **Add** (disabled unless `!parsed.servers.isEmpty` and, if single, name non-empty).
- [ ] **Step 3:** Add → for each parsed server build `AddServerParams(name: single ? name : s.name, kind:, command:, args:, env:, url:, auth: .none, clients: Dictionary(uniqueKeysWithValues: clients.map { ($0, true) }))` → `daemon.add`. Note `AddServerParams` has no `headers` today: if the daemon's `AddServerParams` lacks headers, add `public var headers: [String: String] = [:]` to it (Protocol.swift + Handlers `addServer` passes it into `Server(headers:)`) — that IS a small protocol change; do it, it's additive and decodes with default.
- [ ] **Step 4:** build; try pasting a README JSON with the live daemon (add then remove a test server); **Commit** `feat(app): smart-paste Add sheet with advanced disclosure`.

---

### Task 6: Polish + smoke

- [ ] `caikins-swiftui` + `emil-design-eng` skills: pass over hover states (cards lift `.scaleEffect(1.01)`/brighter border on hover), press feedback on chips, `.animation(.snappy)` on toggle/overlay changes, reduced-motion respect, VoiceOver labels on icon-only buttons, dark/light check.
- [ ] Verify against the live daemon: popover heroes update on toggle; grid filter/search; inspector edits args and they land in the client file (check `~/.cursor/mcp.json` for a test server, then remove it); Add via JSON paste; Remove via ⌫ + confirm.
- [ ] Update `README.md` screenshots section (text only) and commit `docs: UI redesign notes`.

## Self-review
- Spec §2.1 → Task 3; §2.2 → Task 4; §2.3 → Task 5; §2.4 → Task 2; §4 tests → Tasks 1–2. Protocol: only additive `AddServerParams.headers` (Task 5). Names used consistently: `SmartPasteParser.parse → Result{servers, summary}`, `IconSource.resolve(name:kind:url:command:)`, `ServerIcon(server:size:)`, `DaemonClient.update(_:)`, `.glassCard(selected:)`, `.pill()`, `Hairline`, `HeroNumber`, `TextTabs`.
