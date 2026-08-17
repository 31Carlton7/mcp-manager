# MCP Manager — Design Spec

**Date:** 2026-08-17
**Status:** Approved design, pre-implementation
**Platform:** macOS 26+, Swift 6 / SwiftUI
**Distribution:** Homebrew cask (own tap)

## 1. Problem

MCP server configuration is fragmented across every AI client on a Mac. Today Carlton has MCP configs in four places:

| Client | Config | Format |
|---|---|---|
| Claude Code | `~/.claude.json` (`mcpServers`, user scope) | JSON |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON |
| Cursor | `~/.cursor/mcp.json` | JSON |
| Codex | `~/.codex/config.toml` (`[mcp_servers.<name>]`) | TOML |

Adding a server means editing four files. Remote OAuth servers (Notion, Linear, GitHub…) are worse: each client runs its own OAuth flow and stores its own tokens, so you sign in to Notion four times, and Claude Desktop can't do OAuth-remote from config at all.

## 2. Vision and v1 scope

**Vision:** one place to manage MCP servers on a Mac — config hub, runtime monitor, auth manager.

**v1 (this spec): the config hub + centralized OAuth.**

In scope:
- Canonical library of MCP servers, synced to N clients via pluggable adapters (Claude Code, Claude Desktop, Cursor, Codex in v1).
- Per-server, per-client enable matrix.
- Import of servers already present in client configs (adopt, never clobber).
- Centralized OAuth: sign in once, tokens in Keychain, a local auth gateway injects them for every client.
- Catalog of popular servers (bundled curated list + official registry) and paste-JSON import.
- Menu bar popover for status/quick actions + a full window for management.
- Homebrew cask install; background daemon survives app quit.

Out of scope for v1 (designed-for, not built):
- Proxying/supervising stdio servers (single-instance multiplexing, logs, restart) — "runtime monitor".
- Project-scoped configs (`.mcp.json`, per-project entries in `~/.claude.json`, `.cursor/mcp.json` in repos).
- Additional client adapters (Windsurf, Zed, VS Code, Gemini CLI) — the adapter protocol makes each a small file.
- Sparkle auto-update (Brew upgrade suffices).
- Windows/Linux.

## 3. Key decisions (and why)

| Decision | Choice | Why |
|---|---|---|
| Source of truth | Hybrid: canonical library, but client files are imported on change; *library wins on shape, client wins on presence* | Survives people who also use `claude mcp add` / hand-edit; one-sentence conflict rule |
| OAuth depth | Daemon runs PKCE + dynamic client registration, stores tokens, exposes a localhost gateway that injects Bearer | Only approach that makes "sign in once" true across all clients; also gives Claude Desktop OAuth-remote |
| Gateway reach | Remote (`auth: oauth`/`header`) servers only; stdio written straight to clients | Smallest v1 blast radius; runtime-monitor mode is additive later |
| Stack | Native Swift/SwiftUI, Hummingbird 2 for HTTP | Best macOS feel, Keychain/LaunchAgent trivial, Carlton's existing Swift experience |
| Process topology | LaunchAgent daemon `mcpmd` + thin `MCP Manager.app` | Quitting the app must not kill every client's remote servers |
| UI shape | Menu bar status popover + full management window | Popover for glance/quick fix; window for the matrix and editing |
| Add-server UX | Catalog + paste-JSON + manual form | Every README ships an `mcpServers` snippet; catalog covers the popular 80% |

## 4. Architecture

Two Swift targets, one workspace, one cask.

```
┌──────────────────────┐   unix socket    ┌─────────────────────────────────┐
│ MCP Manager.app      │ ───────────────▶ │ mcpmd (LaunchAgent, KeepAlive)  │
│ SwiftUI, thin client │ ◀─── status ──── │  • Control API (JSON over sock) │
│ MenuBarExtra + window│                  │  • Store  ~/.mcpm/servers.json  │
│ opens OAuth in browser│                 │  • Keychain (tokens, client_id) │
└──────────────────────┘                  │  • Sync engine + ClientAdapters │
                                          │  • Auth gateway 127.0.0.1:7337  │
                                          └────────┬───────────────┬────────┘
                       writes config / imports ◀───┘               │ Bearer
┌──────────────────────┐                                           ▼
│ Claude Code, Desktop │ ── http://localhost:7337/s/<id>/mcp ──▶ remote MCP servers
│ Cursor, Codex        │    (remote servers)                     (Notion, Linear, …)
│ spawn stdio as today │
└──────────────────────┘
```

### 4.1 `mcpmd` (daemon)
- Swift executable, installed as `~/Library/LaunchAgents/co.charmtechnologies.mcpmd.plist` (`RunAtLoad`, `KeepAlive`), pointing into the app bundle (`MCP Manager.app/Contents/MacOS/mcpmd`).
- Owns all state and all side effects: library file, Keychain, client config writes, gateway.
- Components: `ControlServer`, `Store`, `SyncEngine`, `ClientAdapter`s, `AuthManager`, `Gateway`, `Catalog`.
- Logs via `os.Logger` (subsystem `co.charmtechnologies.mcpmd`); no request bodies ever logged.

### 4.2 `MCP Manager.app`
- SwiftUI, `MenuBarExtra(.window)` + a `NavigationSplitView` main window. `LSUIElement = true` (no Dock icon) — window shows on demand.
- Contains one `@Observable DaemonClient`: connects to the socket, subscribes to the status stream, exposes async commands. All UI is a projection of the stream; the only optimistic state is toggles, which revert on daemon error.
- On first launch: installs/bootstraps the LaunchAgent (`launchctl bootstrap gui/$UID …`), runs onboarding.
- Never touches config files or tokens directly.

### 4.3 Control API (Unix socket `~/.mcpm/mcpmd.sock`, mode 0600)
Newline-delimited JSON, request/response plus one long-lived `subscribe` stream.

Commands (v1): `hello {appVersion}` → `{daemonVersion, apiVersion}`; `status` / `subscribe`; `servers.list`; `servers.add {server}`; `servers.update {id, patch}`; `servers.remove {id}`; `servers.setClient {id, client, enabled}`; `servers.setAll {id, enabled}`; `servers.test {id}`; `clients.list`; `clients.reimport {client}`; `auth.start {id}` → `{authorizeURL}`; `auth.signOut {id}`; `auth.setHeader {id, name, value}`; `catalog.list {query?}`; `catalog.refresh`; `settings.get/set`; `daemon.restart`.

Version handshake: app refuses a daemon with a different `apiVersion` major and offers "Restart daemon" (`launchctl kickstart -k`), which relaunches the newer binary from the updated bundle.

### 4.4 Gateway (`127.0.0.1:7337`, Hummingbird 2)
Routes:
- `POST|GET|DELETE /s/<serverId>/mcp` — proxy to the server's real URL. Streamable HTTP and SSE pass through unbuffered. `Mcp-Session-Id` forwarded in both directions untouched.
- `GET /oauth/callback` — OAuth redirect target.
- `GET /healthz` — liveness for the app.

Per-request behaviour:
1. Look up server; unknown id → 404.
2. Reject if `Host` header isn't `localhost`/`127.0.0.1[:port]` (DNS-rebinding guard).
3. Strip any client-sent `Authorization`.
4. `auth: oauth` — get token; if `expiry - now < 60s`, refresh first (serialized per server via an actor). `auth: header` — attach the stored header. `auth: none` remote servers are *not* routed through the gateway; they're written to clients with their real URL.
5. Forward with `URLSession` streaming. On upstream 401 for oauth: refresh once, retry once.
6. On refresh failure or missing token: respond `401 {"error":"unauthorized","message":"Sign in to <name> in MCP Manager"}`, set server status `needsAuth`.

Port configurable in Settings; changing it rewrites all client configs and restarts the daemon.

### 4.5 AuthManager (OAuth per MCP spec)
- Discovery: `GET <resource>/.well-known/oauth-protected-resource` → authorization server → `/.well-known/oauth-authorization-server` (fallback: OpenID config; fallback: well-known at origin).
- Client registration: dynamic (`POST registration_endpoint`, redirect `http://localhost:7337/oauth/callback`, `token_endpoint_auth_method: none`). If unsupported, the app shows a sheet to paste `client_id` (+ optional secret).
- Authorize: PKCE S256, `state` = random 32 bytes, single-use, 10-minute TTL, stored in memory keyed to server id. `resource` parameter set to the server URL (RFC 8707) when the metadata advertises support.
- Callback: validate state, exchange code, persist `{accessToken, refreshToken?, expiresAt, clientId, clientSecret?, tokenEndpoint, scope}` in Keychain item `mcpm.<serverId>`; reply with a minimal "Connected — you can close this tab" HTML page; push status `connected`.
- Sign out: call `revocation_endpoint` if advertised, then delete the Keychain item. "Forget" also deletes the registered `client_id`.
- Refresh: standard `refresh_token` grant; rotate stored tokens; if refresh returns `invalid_grant` → `needsAuth`.

Keychain: `kSecAttrAccessibleAfterFirstUnlock`, no iCloud sync, shared access group between app and daemon (same Team ID) even though the app never reads tokens.

## 5. Data model

`~/.mcpm/servers.json` (canonical library, written atomically):

```json
{
  "version": 1,
  "servers": [
    {
      "id": "notion",
      "name": "Notion",
      "kind": "remote",
      "url": "https://mcp.notion.com/mcp",
      "auth": "oauth",
      "clients": { "claude-code": true, "claude-desktop": true, "cursor": false, "codex": true },
      "source": "catalog:notion",
      "createdAt": "2026-08-17T10:00:00Z"
    },
    {
      "id": "playwright",
      "name": "Playwright",
      "kind": "stdio",
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest"],
      "env": {},
      "auth": "none",
      "clients": { "claude-code": true, "claude-desktop": false, "cursor": true, "codex": false },
      "source": "imported:cursor",
      "createdAt": "2026-08-17T10:00:00Z"
    }
  ]
}
```

- `id`: slug, unique, derived from name on create; immutable.
- `kind`: `stdio | remote`.
- `auth`: `none | oauth | header`. `header` stores `{name, value}` in Keychain, never in the library file.
- `headers`: static HTTP headers for remote servers (persisted; secret-bearing headers move to Keychain with `auth: header` in Plan 2). Written to clients only when the server does not route through the gateway.
- `clients`: the enable matrix; keys are adapter ids. Missing key = false.
- `source`: `catalog:<slug> | imported:<client> | manual | pasted`.
- Runtime status (`connected | needsAuth | expiring | unhealthy | ok`) is *not* persisted; it lives in daemon memory and the status stream.

Neutral `ExternalServer` struct used by adapters: `{name, kind, command?, args?, env?, url?, headers?}` — exactly what a client file can express.

## 6. Client adapters

```swift
protocol ClientAdapter: Sendable {
    var id: ClientID { get }              // "claude-code", "claude-desktop", "cursor", "codex"
    var displayName: String { get }
    var configPath: URL { get }
    func isInstalled() -> Bool            // app bundle or config dir exists
    func read() throws -> ClientSnapshot  // { servers: [ExternalServer], raw: Data }
    func write(_ servers: [ExternalServer], over raw: Data?) throws -> Data
    // write must preserve every byte/key not under its MCP section
}
```

Adapter notes:
- **ClaudeCode** — `~/.claude.json`, top-level `mcpServers` only (user scope). Per-project entries under `projects.<path>.mcpServers` are read-only in v1 (shown as "project-scoped, not managed"). Claude Code's own OAuth-connected remote servers are left as-is unless the user toggles them into the library.
- **ClaudeDesktop** — `mcpServers`, historically stdio-only (`command`/`args`/`env`). Remote servers are written as a stdio bridge: `{"command":"npx","args":["-y","mcp-remote","http://localhost:7337/s/<id>/mcp"]}`. The bridge needs no auth of its own because the gateway injects the token. If, at implementation time, Desktop's config format supports native `url` / `type: "http"` entries, the adapter writes that instead; the choice is verified during implementation and pinned by the adapter's golden tests.
- **Cursor** — `~/.cursor/mcp.json`, `mcpServers`, supports `command` and `url`.
- **Codex** — `~/.codex/config.toml`, `[mcp_servers.<name>]` tables with `command`/`args`/`env` and `url` for remote. TOML round-trip must preserve comments and unrelated tables (use a preserving TOML library or targeted table replacement).

Adding a client later = one new file conforming to `ClientAdapter` + a golden-file test.

## 7. Sync engine

Pure core: `func plan(library: Library, snapshots: [ClientID: ClientSnapshot]) -> (Library, [ClientID: WritePlan])`. The daemon wraps it with I/O.

Triggers: daemon start; FSEvents on any adapter `configPath` (debounced 500 ms); any library mutation via the Control API; manual "Re-import".

Algorithm:
1. **Import.** For each snapshot, each `ExternalServer` not matching a library entry (match order: name; then remote URL; then command+args) is adopted: new library entry, `clients[thisClient] = true`, all others false, `source: imported:<client>`. Entries the gateway wrote (URL matches `localhost:<port>/s/<id>/mcp`) map back to `<id>` and are not re-adopted.
2. **Presence.** A library server with `clients[c] == true` that is absent from `c`'s snapshot → set `clients[c] = false` (respect CLI removals). Exception: *suppressed* clients — those we wrote within the last 2 s, and all clients during a sync triggered by an app-side mutation — have stale snapshots and are **projected only**: no adoption, no presence changes for them in that pass.
3. **Project.** For each adapter: desired list = library entries with `clients[adapter] == true`, converted to `ExternalServer`; remote `oauth`/`header` servers become `url: http://localhost:<port>/s/<id>/mcp`.
4. **Write** only if desired ≠ current. Atomic (temp file + rename), copy previous file to `~/.mcpm/backups/<client>/<ISO-timestamp>.<ext>` (keep last 5), then arm a 2 s self-suppress window for that adapter's watcher.
5. **Conflict rule:** library wins on shape (command/args/env/url), client wins on presence. That is the entire policy and it is stated verbatim in the Clients tab.

Errors: adapter `read()` fails → adapter marked `unhealthy` with the parse error; no writes to that client until it reads cleanly. Adapter not installed → hidden from the matrix. Library file corrupt → daemon refuses to start syncing, status stream carries the error, app shows a "Restore from backup" action.

Servers with `env` values: we never invent env; on write we emit exactly the library's `env`. On import, env values come in as-is (they may be secrets; they live only in `servers.json`, mode 0600, and the client files where they already were).

## 8. Catalog

- `Catalog/servers.json` bundled in the app: ~20 curated entries (Notion, Linear, GitHub, Sentry, Playwright, Context7, Filesystem, Fetch, Slack, Figma, Stripe, Supabase, Vercel, Cloudflare, Atlassian, Asana, HubSpot, Postgres, Puppeteer, Memory). Each: `{slug, name, description, kind, url|command/args, auth, homepage, icon?}`.
- Live source: official registry (`https://registry.modelcontextprotocol.io`, `/v0/servers` search). Fetched on demand, cached at `~/.mcpm/catalog-cache.json` for 24 h. Registry entries are normalized into the same shape; entries needing package install (npm/pypi) map to `npx -y <pkg>` / `uvx <pkg>`.
- Bundled entries take precedence over registry entries with the same slug.
- Paste-JSON: accepts a full `{"mcpServers": {...}}` object, a single `{"name": {...}}` map, or a bare server object; parses into `[ExternalServer]` and opens the add sheet pre-filled (multiple → adds all).

## 9. UI

### 9.1 Menu bar popover
- Icon: plug SF Symbol; tint green (all ok), yellow (≥1 `needsAuth`/`expiring`), red (daemon unreachable or ≥1 adapter unhealthy).
- Header: "N servers · M clients", daemon pip.
- Rows: status dot · name · master toggle (sets all installed clients on/off). `needsAuth` rows show an inline **Sign in** button.
- Footer: **Add server…** (opens window on Catalog), **Open MCP Manager…**, **Quit MCP Manager** (help text: "The background service keeps running").

### 9.2 Main window (`NavigationSplitView`)
- **Servers** — `Table`: name · kind badge · auth status · one checkbox column per installed adapter. Inspector on selection: editable fields (name; command/args/env or URL; auth type), per-client toggles, **Test connection** (stdio: spawn, MCP `initialize`, report server name/version/tool count, kill; remote: gateway round-trip `initialize`), **Remove**.
- **Catalog** — search field, grid of cards with **Add** → pre-filled sheet (all installed clients checked by default) → Servers. **Paste JSON** button.
- **Clients** — card per adapter: installed?, config path (reveal in Finder), last import/write times, **Re-import now**, **Show backups**, health/error text, and the conflict-rule sentence.
- **Auth** — oauth/header servers with state, **Sign in / Sign out / Forget**, and expiry.
- **Settings** — launch app at login, gateway port, backup retention, **Reinstall background service**, **Restart background service**, log location.

### 9.3 Onboarding (first launch)
1. Install background service (explains what a LaunchAgent is; one button).
2. "Found N servers across Claude Code, Cursor, Codex" — checked list, **Import**.
3. Done — points at the menu bar icon.

Visual language: macOS Tahoe / Liquid Glass per the SwiftUI skill; concrete visual polish is an implementation-phase concern.

## 10. Distribution & operations

- **Homebrew cask** in `carltonaikins/homebrew-tap`: `brew install --cask carltonaikins/tap/mcp-manager`. Artifact: notarized `.dmg` on GitHub Releases. Cask stanzas: `app "MCP Manager.app"`, `uninstall launchctl: "co.charmtechnologies.mcpmd"`, `zap trash: ["~/.mcpm", "~/Library/LaunchAgents/co.charmtechnologies.mcpmd.plist"]`.
- **Release CI** (GitHub Actions, macOS runner): build → codesign (Developer ID Application) → `xcrun notarytool submit --wait` → staple → attach to release → bump cask formula via PR to the tap.
- **Upgrade path**: `brew upgrade` swaps the bundle; running daemon is the old binary until app relaunch triggers the version handshake and offers restart (or the app restarts it silently when major matches).
- **Uninstall from the app**: Settings → "Uninstall background service" (bootout + remove plist), and a note that `brew uninstall --zap` removes everything.

## 11. Security

- Tokens and header secrets only in Keychain; library file never contains them.
- Gateway loopback-only, `Host` check, strips inbound `Authorization`, never logs bodies. Deferred hardening (not v1): per-boot bearer written into client configs.
- Control socket 0600; API accepts connections only from same UID (peer-cred check).
- Client config writes never introduce env values not already in the library; backups before every write.
- OAuth: PKCE S256, single-use short-TTL `state`, exact redirect match, `resource` indicator when supported.

## 12. Testing

- **MCPMCore (adapters, sync):** golden-file tests using anonymized real configs for each client (parse → plan → write → byte-compare; unrelated keys/comments preserved; TOML round-trip). Table-driven tests for the sync rules: adopt new, respect removal, self-suppress, name/URL/command matching, gateway-URL mapping back to id, unhealthy adapter skipped.
- **MCPMGateway:** in-process Hummingbird tests against a fake upstream + fake auth server (metadata, DCR, token, revocation): happy proxy, SSE passthrough, session id passthrough, proactive refresh, 401→refresh→retry, refresh failure → 401 body + `needsAuth`, Host-header rejection, Authorization stripping, concurrent calls trigger a single refresh.
- **AuthManager:** state validation (bad/expired/reused), discovery fallbacks, DCR-unsupported path.
- **Control API:** protocol round-trip tests over a temp socket; version handshake mismatch.
- **App:** ViewModel tests with a mocked `DaemonClient` fixture stream; one XCUITest for onboarding → import → server appears.
- **CI:** `swift test` for the package; `xcodebuild test` for the app; both on every PR.

## 13. Repository layout

```
mcp-manager/
  Package.swift                 # targets: MCPMCore, MCPMGateway, mcpmd (executable), tests
  Sources/MCPMCore/             # models, Store, adapters/, SyncEngine, Catalog
  Sources/MCPMGateway/          # Gateway, AuthManager, Keychain
  Sources/mcpmd/                # main, ControlServer, wiring
  Apps/MCPManager/              # Xcode project: SwiftUI app, DaemonClient, onboarding
  Catalog/servers.json
  Homebrew/mcp-manager.rb
  Tests/                        # MCPMCoreTests, MCPMGatewayTests, fixtures/
  docs/superpowers/specs/
```

## 14. Milestones (for the implementation plan)

1. Core models + Store + SyncEngine (pure) with tests.
2. Four adapters with golden tests; `mcpmd` runs sync + FSEvents; CLI-less smoke via socket.
3. Control API + minimal app (Servers table, matrix, popover) — end-to-end "toggle → file changes".
4. Gateway + AuthManager + Keychain; Notion/Linear sign-in works from Claude Code and Cursor.
5. Catalog + paste-JSON + onboarding import.
6. Clients/Auth/Settings tabs, LaunchAgent install/restart, version handshake.
7. Signing, notarization, release CI, Homebrew cask.
