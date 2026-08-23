# MCP Manager — Plan 2: Auth Gateway + OAuth + Test Connection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks touching `Apps/MCPManager` MUST first invoke the `caikins-swiftui` skill.

**Goal:** Sign in to a remote MCP server (e.g. Notion) once; every client talks to `http://localhost:7337/s/<id>/mcp` and the daemon injects a fresh Bearer token. Plus "Test connection" for any server.

**Architecture:** New `MCPMGateway` module: `TokenStore` (Keychain, with a file store for dev/tests), `OAuthClient` (RFC 9728/8414 discovery, RFC 7591 dynamic registration, PKCE S256 authorization-code + refresh, RFC 8707 `resource`), `AuthManager` actor (per-server auth state machine, serialized refresh), `Gateway` (Hummingbird 2 HTTP server on 127.0.0.1: proxy `/s/{id}/mcp` with header stripping/Bearer injection/401-refresh-retry/streaming passthrough, `/oauth/callback`, `/healthz`), `MCPProbe` (initialize handshake for remote + stdio). `mcpmd` wires it, adds `auth.*` + `servers.test` control commands and real per-server auth states. App gains Sign in / Sign out / Test / header entry. `SyncEngine` already emits gateway URLs for `auth: oauth|header` servers.

**Tech Stack:** Swift 6.2, Hummingbird 2.x (`Hummingbird`, `HummingbirdTesting`), `URLSession` (streaming `bytes(for:)`), CryptoKit (PKCE), Security.framework (Keychain), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-17-mcp-manager-design.md` §4.4, §4.5, §11.

**Verified target:** `https://mcp.notion.com/.well-known/oauth-protected-resource` → AS `https://mcp.notion.com` with `authorization_endpoint /authorize`, `token_endpoint /token`, `registration_endpoint /register`, `revocation_endpoint /token`, PKCE S256, `token_endpoint_auth_methods_supported` includes `none`, scopes `["default"]`.

---

## File structure

```
Package.swift                              + hummingbird dep, MCPMGateway target + tests
Sources/MCPMGateway/
  Tokens/TokenStore.swift                  protocol + TokenRecord
  Tokens/FileTokenStore.swift              0600 JSON under ~/.mcpm (dev/tests)
  Tokens/KeychainTokenStore.swift          generic-password items "mcpm.<serverId>"
  OAuth/OAuthMetadata.swift                Codable metadata + discovery URL rules
  OAuth/PKCE.swift                         verifier/challenge/state
  OAuth/OAuthClient.swift                  discovery, DCR, authorize URL, code exchange, refresh, revoke (injectable HTTP)
  OAuth/HTTPClient.swift                   protocol over URLSession (for tests)
  AuthManager.swift                        actor: state per server, startAuth/handleCallback/token(for:)/signOut/setHeader
  Gateway/Gateway.swift                    Hummingbird app: routes + proxy
  Gateway/Proxy.swift                      upstream forwarding with streaming
  Probe/MCPProbe.swift                     initialize handshake: remote (via URL) + stdio (Process)
Tests/MCPMGatewayTests/
  FileTokenStoreTests.swift, PKCETests.swift, OAuthMetadataTests.swift, OAuthClientTests.swift (fake HTTP),
  AuthManagerTests.swift, GatewayTests.swift (fake upstream + fake AS via Hummingbird on ephemeral ports),
  MCPProbeTests.swift (fake remote via Hummingbird; fake stdio via bundled python script)
  Fixtures/fake_stdio_server.py
Sources/MCPMControl/Protocol.swift         + auth.start/auth.signOut/auth.setHeader/servers.test, AuthState, TestResult
Sources/mcpmd/ControlHandlers.swift        + handlers, real states, allow auth kinds
Sources/mcpmd/MCPMD.swift                  wire AuthManager + Gateway; broadcast on auth-state change
Apps/MCPManager/Sources/…                  DaemonClient commands; inspector Auth section + Test; popover Sign in pill; Add sheet auth picker
```

---

### Task 1: Module scaffold + TokenStore (file + Keychain)

**Files:** `Package.swift`; `Sources/MCPMGateway/Tokens/{TokenStore,FileTokenStore,KeychainTokenStore}.swift`; `Tests/MCPMGatewayTests/FileTokenStoreTests.swift`

- [ ] Package: add `.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0")`; target `MCPMGateway` deps `MCPMCore`, `.product(name: "Hummingbird", package: "hummingbird")`; test target deps `MCPMGateway`, `.product(name: "HummingbirdTesting", package: "hummingbird")`, resources `.copy("Fixtures")`. `mcpmd` depends on `MCPMGateway`.
- [ ] `TokenRecord: Codable, Equatable, Sendable { accessToken, refreshToken?, expiresAt: Date?, tokenType: String, scope: String?, clientID: String, clientSecret: String?, tokenEndpoint: URL, revocationEndpoint: URL?, resource: String? }` and `HeaderSecret: Codable { name, value }`.
- [ ] `protocol TokenStore: Sendable { func token(for id: String) throws -> TokenRecord?; func setToken(_:for:) throws; func removeToken(for:) throws; func header(for id: String) throws -> HeaderSecret?; func setHeader(_:for:) throws; func removeHeader(for:) throws; func clientRegistration(for id: String) throws -> ClientRegistration?; func setClientRegistration(_:for:) throws }` with `ClientRegistration { clientID, clientSecret?, issuer: URL }`.
- [ ] `FileTokenStore(url:)` — one JSON file `{tokens:{id:…}, headers:{…}, registrations:{…}}`, `AtomicFile.write(mode: 0o600)`; tests: round trip, remove, missing → nil, file mode 0600.
- [ ] `KeychainTokenStore(service: "co.charmtechnologies.mcpm")` — `SecItemAdd/Update/CopyMatching/Delete` generic passwords, account = `"token.<id>"` / `"header.<id>"` / `"client.<id>"`, value = JSON, `kSecAttrAccessibleAfterFirstUnlock`, no iCloud sync. Not unit-tested in CI (mark test `.disabled("touches login keychain")` but keep it runnable manually). Note in code: dev builds of an unsigned `mcpmd` will trigger the standard "wants to use your confidential information" prompt after a rebuild — use `MCPM_TOKEN_STORE=file` env to select the file store during development (`MCPMD` reads it; default is Keychain).
- [ ] Commit `feat(gateway): MCPMGateway scaffold + TokenStore (file, keychain)`.

### Task 2: PKCE + OAuth metadata + OAuthClient (with fake HTTP)

**Files:** `OAuth/{PKCE,OAuthMetadata,HTTPClient,OAuthClient}.swift`; tests.

- [ ] `PKCE.verifier()` (43–128 chars from 32 random bytes base64url), `challenge(for:)` (SHA256 base64url), `state()` (32 random bytes base64url). Tests: lengths/charset, known-vector challenge (RFC 7636 appendix B: verifier `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` → challenge `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`).
- [ ] `ProtectedResourceMetadata: Codable { resource, authorization_servers: [String], scopes_supported: [String]? }`; `AuthorizationServerMetadata: Codable { issuer, authorization_endpoint, token_endpoint, registration_endpoint?, revocation_endpoint?, scopes_supported?, code_challenge_methods_supported?, token_endpoint_auth_methods_supported? }`. Discovery URL rules (RFC 9728 §3 / RFC 8414 §3 with path insertion): for resource `https://h/p/q`: PRM candidates `https://h/.well-known/oauth-protected-resource/p/q`, then `https://h/.well-known/oauth-protected-resource`; for AS issuer `https://h/x`: `https://h/.well-known/oauth-authorization-server/x`, `https://h/.well-known/openid-configuration/x`, `https://h/x/.well-known/openid-configuration`, and for issuer with empty path: `https://h/.well-known/oauth-authorization-server`, `https://h/.well-known/openid-configuration`. Fallback when all fail: `authorize`/`token`/`register` at the AS origin. Pure function `discoveryCandidates(resource:) -> [URL]`, `asCandidates(issuer:) -> [URL]` — tested.
- [ ] `protocol HTTPClient: Sendable { func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) }`; `URLSessionHTTPClient`; test `FakeHTTPClient` (dictionary of URL→(status, body), records requests).
- [ ] `OAuthClient(http:)`: `discover(resource: URL) async throws -> Discovery{ prm?, asMeta, scopes }`; `register(asMeta, redirectURI) -> ClientRegistration` (POST JSON `{client_name:"MCP Manager", redirect_uris:[…], grant_types:["authorization_code","refresh_token"], response_types:["code"], token_endpoint_auth_method:"none"}`; if 4xx/no endpoint → throw `.registrationUnsupported`); `authorizeURL(asMeta, clientID, redirectURI, scope?, state, challenge, resource) -> URL` (query: response_type=code, client_id, redirect_uri, code_challenge, code_challenge_method=S256, state, scope?, resource); `exchange(asMeta, code, verifier, clientID, clientSecret?, redirectURI, resource) -> TokenResponse{access_token, token_type, expires_in?, refresh_token?, scope?}` (form-encoded POST; client_secret via `client_secret_post` if present); `refresh(record) -> TokenResponse`; `revoke(record)` (best effort). Tests with FakeHTTPClient: happy discovery (Notion-shaped), PRM-missing fallback to AS at origin, DCR body shape, authorize URL query set, exchange form body incl. `resource`, refresh body, error mapping (`invalid_grant` → `.invalidGrant`).
- [ ] Commit `feat(gateway): PKCE, metadata discovery, OAuthClient`.

### Task 3: AuthManager actor

**Files:** `Sources/MCPMGateway/AuthManager.swift`; `Tests/MCPMGatewayTests/AuthManagerTests.swift`.

- [ ] `public enum AuthState: String, Codable, Sendable { case none, needsAuth, connected, expiring, error }`.
- [ ] `actor AuthManager { init(store: TokenStore, oauth: OAuthClient, redirectURI: URL, now: @Sendable () -> Date = Date.init) }`:
  - `func state(for id: String, auth: AuthKind) -> AuthState` (oauth: token present && (no expiry || expiry > now+60s) → connected; present && expiring within 60 s → expiring; absent → needsAuth. header: present → connected else needsAuth. none → none).
  - `func startAuth(id: String, serverURL: URL) async throws -> URL` — discover, reuse or register client, create PKCE + state, store `pending[state] = (id, verifier, asMeta, clientReg, resource, createdAt)`, return authorize URL. Pending entries expire after 10 min; one pending per server (restart replaces).
  - `func handleCallback(query: [String: String]) async throws -> String /*server id*/` — validate `state` (single-use), `error` param → throw `.providerError(msg)`, exchange code, persist `TokenRecord`, clear pending.
  - `func bearer(for id: String) async throws -> String` — token; if expiring (<60 s) refresh first (serialized per id via an in-actor `refreshing: [String: Task<TokenRecord, Error>]`), returns access token; on missing → throw `.needsAuth`.
  - `func forceRefresh(id:) async throws -> String` (after upstream 401): if no refresh token → remove token, throw `.needsAuth`; `invalid_grant` → remove token, throw `.needsAuth`.
  - `func signOut(id:)` — revoke best-effort, remove token; `func forget(id:)` — also remove registration. `func setHeader(id:name:value:)`, `func header(for:)`.
  - `stateChanged: AsyncStream<String>` (server id) fired on any transition — mcpmd broadcasts status.
- [ ] Tests (FakeHTTPClient + FileTokenStore in temp): full flow start→callback→connected; bad/expired/reused state rejected; expiring → proactive refresh once for two concurrent `bearer` calls (assert one refresh request); 401 path `forceRefresh` with `invalid_grant` → needsAuth and token removed; header state.
- [ ] Commit `feat(gateway): AuthManager`.

### Task 4: Gateway (Hummingbird) + Proxy

**Files:** `Sources/MCPMGateway/Gateway/{Gateway,Proxy}.swift`; `Tests/MCPMGatewayTests/GatewayTests.swift`.

- [ ] `public struct GatewayConfig { host = "127.0.0.1", port = 7337, hostAllowlist = ["localhost","127.0.0.1"] }`; `public protocol GatewayServerSource: Sendable { func server(id: String) async -> Server? ; func markNeedsAuth(id: String) async }` (mcpmd implements via coordinator + broadcasts).
- [ ] `public actor Gateway { init(config:, auth: AuthManager, servers: GatewayServerSource, upstream: URLSession = .shared); func start() async throws; func stop() async }` — builds a Hummingbird `Router`:
  - `GET /healthz` → `{"ok":true}`.
  - `GET /oauth/callback` → `auth.handleCallback(query)` → 200 HTML "Connected — you can close this tab" (or 400 with the error text). Also `POST` not needed.
  - `/s/{id}/mcp` for GET/POST/DELETE → `Proxy.forward`.
- [ ] `Proxy.forward(request, id)`:
  1. `Host` header check (allowlist, port optional) → 403 otherwise.
  2. server lookup → 404 unknown; `auth == .none` → 404 too (not proxied).
  3. Build upstream `URLRequest(url: server.url + same query)`; copy headers except hop-by-hop (`Host`, `Connection`, `Content-Length`, `Transfer-Encoding`, `Keep-Alive`, `Authorization`, `Proxy-*`); collect request body (limit 10 MiB); set `Authorization: Bearer <auth.bearer(id)>` or the stored header for `.header`; forward `Mcp-Session-Id`, `Accept`, `Content-Type`, `Last-Event-ID`.
  4. `upstream.bytes(for:)` → if status 401 and oauth: `forceRefresh` and retry once; if still 401 or refresh throws needsAuth → respond `401 {"error":"unauthorized","message":"Sign in to <name> in MCP Manager"}` and `servers.markNeedsAuth(id)`.
  5. Response: status + headers (drop hop-by-hop; keep `Content-Type`, `Mcp-Session-Id`, `Cache-Control`) + body streamed as `ResponseBody(asyncSequence:)` from the bytes stream (chunk by 16 KiB) — SSE flows unbuffered.
  6. Never log bodies.
- [ ] Tests (Hummingbird test app for a **fake upstream** on ephemeral port: echoes headers, `/sse` streams 3 events with 100 ms gaps, `/needs401` returns 401 first then 200 when a new token appears; **fake AS** endpoints for refresh): happy proxy strips inbound Authorization and injects Bearer; SSE passthrough delivers events incrementally (measure first-event latency < 250 ms); `Mcp-Session-Id` round trip; 401→refresh→retry succeeds; refresh failure → 401 body + `markNeedsAuth`; unknown id 404; auth none 404; bad Host 403; header-auth server injects stored header. Run the Gateway itself on an ephemeral port in tests (`port: 0` support → expose `boundPort`).
- [ ] Commit `feat(gateway): Hummingbird gateway with streaming proxy and OAuth callback`.

### Task 5: MCPProbe (Test connection)

**Files:** `Sources/MCPMGateway/Probe/MCPProbe.swift`; `Tests/MCPMGatewayTests/MCPProbeTests.swift`; `Fixtures/fake_stdio_server.py`.

- [ ] `public struct ProbeResult: Codable, Equatable, Sendable { ok: Bool; serverName: String?; serverVersion: String?; protocolVersion: String?; toolCount: Int?; error: String?; durationMs: Int }`.
- [ ] `MCPProbe.remote(url: URL, headers: [String:String], timeout: 10s)` — POST JSON-RPC `initialize` (`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"MCP Manager","version":"…"}}}`) with `Accept: application/json, text/event-stream`; parse JSON body or SSE (`data:` lines) for the response; capture `Mcp-Session-Id`; then `notifications/initialized` + `tools/list` (best effort) for count; then `DELETE` session (best effort). 401 → `ok:false, error:"needs sign-in"`.
- [ ] `MCPProbe.stdio(command:args:env:timeout: 10s)` — `Process` with pipes, PATH-resolve `command` via `/usr/bin/env` when not absolute (login shell PATH: read `$SHELL -lc 'echo $PATH'` once and cache), write initialize line, read lines until id 1 response, then `initialized` + `tools/list`, terminate. Non-zero exit/timeouts → error with the first stderr line.
- [ ] Fixture `fake_stdio_server.py`: reads JSON lines, answers initialize with `{serverInfo:{name:"fake",version:"1.0"},protocolVersion:…,capabilities:{tools:{}}}` and tools/list with 2 tools. Tests: stdio happy path; stdio bad command → error; remote happy via a Hummingbird fake (JSON and SSE variants); remote 401.
- [ ] Commit `feat(gateway): MCPProbe test-connection`.

### Task 6: Protocol + daemon wiring

**Files:** `Sources/MCPMControl/Protocol.swift`, `Sources/mcpmd/{ControlHandlers,MCPMD}.swift`, tests.

- [x] Protocol: commands `auth.start {id}` → `.authorizeURL(String)`; `auth.signOut {id}`; `auth.forget {id}`; `auth.setHeader {id,name,value}`; `servers.test {id}` → `.testResult(ProbeResult)`. `ServerStatus.state` becomes `AuthState` rawValue strings (`none|needsAuth|connected|expiring|error`) — keep the field a `String` for wire compat but populate from AuthManager. Add `gatewayPort: Int` to `DaemonStatus`. Round-trip tests.
- [x] Handlers: remove the "auth not available" guard; validate `auth: .header` requires a subsequent `auth.setHeader` (state needsAuth until then); `updateServer` may change `auth`. `status()` asks `auth.state(for:auth:)` per server. `servers.test`: for remote `auth != .none` → probe through the gateway URL (`http://127.0.0.1:port/s/id/mcp`), else the real URL with `headers`; stdio → `MCPProbe.stdio`.
- [x] `MCPMD`: build `TokenStore` (`MCPM_TOKEN_STORE=file` → `FileTokenStore(paths.root/tokens.json)`; default Keychain), `AuthManager`, `Gateway` (port from `MCPM_GATEWAY_PORT` env, default 7337; `GatewayServerSource` backed by the coordinator; `markNeedsAuth` just triggers a status broadcast); start gateway before the first sync; forward `auth.stateChanged` into the existing status-push stream. Log gateway start/failure. If the port is busy → log + `lastError`, keep running (config hub still works).
- [x] Smoke (scratch HOME + `MCPM_TOKEN_STORE=file`): `servers.add` a remote oauth server pointing at Notion → `auth.start` returns a real `https://mcp.notion.com/authorize?...` URL (do NOT open it); `status` shows `needsAuth`; `/healthz` responds; unknown `/s/x/mcp` 404. Kill after; nothing under real ~.
- [x] Commit `feat(mcpmd): auth commands, gateway wiring, real auth states, servers.test`.

### Task 7: App — Sign in / Sign out / Test / header auth

**Files:** `Apps/MCPManager/Sources/{DaemonClient,MenuBarView,MainWindow/*}.swift`.

- [x] `DaemonClient`: `startAuth(id)` (awaits `.authorizeURL`, then `NSWorkspace.shared.open(url)`), `signOut(id)`, `forget(id)`, `setHeader(id,name,value)`, `test(id) async -> ProbeResult?` (result stored per id in `testResults: [String: ProbeResult]`, `testing: Set<String>`), `attentionCount` counts `needsAuth`/`error`.
- [x] Inspector: **Auth** section under Connection: state line with dot (green connected / yellow needsAuth / red error), buttons: oauth → "Sign in…" / "Sign out" / "Forget" (menu); header → name+value fields (value `SecureField`) + Save; none → picker to switch auth kind (None / OAuth / Header) via `update(auth:)` with a caption "Clients will be pointed at the local gateway". **Test** button enabled → spinner → inline result ("fake 1.0 · 12 tools · 340 ms" or red error).
- [x] Popover: rows with `needsAuth` show the yellow "Sign in" pill (tap → `startAuth`); Needs-attention hero counts them.
- [x] Add sheet: Advanced → Auth picker enabled (None / OAuth / Header); Header shows name/value fields; on Add, if header → `auth.setHeader` after add (DaemonClient chains it after the ack).
- [x] Card subline: yellow "needs sign-in" for `needsAuth` (already), green dot suffix for connected.
- [x] Build clean; commit `feat(app): sign in / sign out / test connection / header auth`. (Relaunch deferred to Task 8, which restarts both the daemon and the app.)

### Task 8: Real-world smoke with Notion (needs the human for the browser step)

- [ ] Restart the daemon from `master` build against the real home (backups still in `~/mcpm-manual-backup/`; take fresh ones). Default Keychain store (expect one macOS Keychain prompt on first token write; "Always Allow").
- [ ] In the app: select `notion` → Auth → switch to OAuth (clients get rewritten to `http://localhost:7337/s/notion/mcp`; Claude Desktop via `mcp-remote` bridge) → **Sign in…** → browser → callback → state `connected`. Test → shows Notion server info + tool count. In Claude Code: `claude mcp list` shows notion at the gateway URL; a tool call works. Record results in this plan.

## Self-review
Spec §4.4 routes/behaviour → Task 4; §4.5 OAuth → Tasks 2–3; §11 security (loopback, Host check, strip Authorization, no body logs, Keychain, 0600) → Tasks 1, 4; `auth.*` commands → Task 6; UI → Task 7. Names: `TokenStore/TokenRecord/HeaderSecret/ClientRegistration`, `OAuthClient`, `AuthManager.startAuth/handleCallback/bearer/forceRefresh/signOut/forget/setHeader/state(for:auth:)/stateChanged`, `Gateway/GatewayConfig/GatewayServerSource`, `MCPProbe.remote/stdio → ProbeResult`, `AuthState`, protocol `.authorizeURL/.testResult`, `DaemonStatus.gatewayPort`.

## Smoke test 2026-08-22 (Task 8, real machine, Notion)

| Check | Result |
|---|---|
| Switch `notion` to OAuth in the inspector | ✅ All four client configs rewritten to `http://localhost:7337/s/notion/mcp` (Claude Desktop via `mcp-remote` bridge). |
| Sign in… → browser consent → callback | ✅ Discovery + dynamic client registration + PKCE against `mcp.notion.com`. First attempt failed at the Keychain write (`UNIX[Operation not permitted]`) because the daemon had been hand-started from a sandboxed shell after a reboot; restarted un-sandboxed → token stored as `co.charmtechnologies.mcpm / token.notion`. |
| State | ✅ `connected` |
| Test connection (through the gateway) | ✅ `Notion MCP 1.2.0 · 28 tools · 750 ms` |
| Lessons | The daemon must be launchd-started (LaunchAgent) — hand-started daemons inherit the parent's sandbox/TCC context and die on reboot. Tracked as the next work item. |
