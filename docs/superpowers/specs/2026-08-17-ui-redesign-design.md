# MCP Manager — UI Redesign (Plan 1.5) Design Spec

**Date:** 2026-08-17 · **Status:** approved · **Scope:** app only (`Apps/MCPManager`) plus one small pure helper in `MCPMCore` (smart-paste parser). No daemon/protocol changes.

## 1. Goal

Replace the skeleton UI (plain `Table` + tiny popover) with a modern, glass-based interface modelled on Jason Jun's Vercel Analytics menu-bar app: tall rounded popover with pill dropdowns, hero numbers, hairline dividers, small tab labels and a quiet footer; a main window with a **grid of server cards** and a **right inspector**; a simplified **Add** flow that hides advanced fields. Use macOS 26 **Liquid Glass** (`glassEffect`, `GlassEffectContainer`, materials) instead of the video's white surfaces.

## 2. Surfaces

### 2.1 Popover (`MenuBarExtra(.window)`, ~330 pt wide)
- Header row: `Menu` styled as a pill — **client filter** ("All clients", or one installed client) — and a trailing round glass button that opens the main window.
- **Hero numbers** (three columns, 34-pt semibold, letter-spacing −2%): *Active* (servers enabled in ≥1 client under the current filter), *Clients* (installed count), *Needs attention* (yellow when >0; counts `needsAuth` servers + unhealthy clients).
- Hairline divider.
- Two small tab labels **Servers | Clients** (Picker with `.segmented` disguised as text tabs, or a custom text picker).
  - *Servers*: rows = icon (26 pt rounded 7) · name · optional yellow "Sign in" pill (Plan 2) · trailing `Toggle(.switch, .mini)` = master toggle under the current filter (if a client filter is set, the switch is that client's flag; else `setAll`).
  - *Clients*: rows = client name · health dot · "N servers" · Re-import button.
- Hairline; footer caption row: "Synced HH:mm" (from newest `lastSync`) · "Open MCP Manager ↗".
- Error captions (command `lastError` red, daemon `lastError` orange) between list and footer, as today.
- Disconnected state: hero numbers dimmed, header shows "Background service unreachable" — same gating as today.
- Rows in a `ScrollView` sized to content, `maxHeight` 320.

### 2.2 Main window (`Window("MCP Manager", id: "main")`, min 820×520)
- `.windowStyle(.hiddenTitleBar)`; content on a glass/material background (`.containerBackground(.ultraThinMaterial, for: .window)` or the Tahoe equivalent — implementer follows the SwiftUI skill).
- **Toolbar / header row**: client-filter pill, kind-filter pill (All / stdio / remote), search field (`.searchable` or a glass text field), **+ Add** primary button.
- **Grid**: `LazyVGrid` with adaptive columns (min 220 pt), 10 pt spacing, inside a `ScrollView`. Card = glass rounded-16 surface: top row icon (26) + name (13 semibold) + subline (kind · transport/auth or "needs sign-in" in yellow); bottom row = **client chips** (one per installed client, green-tinted when enabled). Selected card gets a brighter border. Click selects; ⌫ removes (with confirmation); double-click focuses the inspector.
- **Inspector** (right split panel, `.inspector(isPresented:)`, 250–300 pt): icon (34) + name + host/command subline; **Enabled in** — one `.switch` per installed client; **Connection** — URL or command+args in monospace, auth state line; **Advanced** disclosure — headers (remote) / env + args (stdio) editable; **Test** (Plan 3, disabled with tooltip) and **Remove** (destructive, confirmation). Empty selection shows a placeholder ("Select a server").
- Filters and search apply to the grid; counts in the header pill show the filtered count.

### 2.3 Add sheet
- One **smart paste** multiline field: accepts a URL (→ remote), a command line (→ stdio: first token command, rest args), or a README JSON snippet (`{"mcpServers":{…}}`, a `{"name":{…}}` map, or a bare server object → may yield several servers). Parsed live; a summary line under the box says what was detected ("Remote server · mcp.notion.com" / "2 servers from JSON").
- **Name** (auto-filled from JSON key / host / command basename; editable), **Enable in** client chips (all installed on by default).
- **Advanced** disclosure: args, env (key/value list), headers (remote), auth (Picker, disabled — "available in a later version").
- Add is disabled until the parse yields ≥1 valid server. Multiple servers → adds all.

### 2.4 Icons
- `ServerIcon` view: bundled asset for known slugs (asset catalog `Icons/<slug>` for ~20 popular servers: notion, linear, github, playwright, context7, exa, figma, slack, sentry, stripe, supabase, vercel, cloudflare, atlassian, asana, hubspot, postgres, filesystem, fetch, memory, mobbin, nia…); otherwise for `remote` servers a favicon fetched by the app from `https://<host>/favicon.ico` (fallback `https://www.google.com/s2/favicons?domain=<host>&sz=64`), cached at `~/Library/Caches/co.charmtechnologies.mcpmanager/icons/<host>.png`; otherwise a **monogram** (first 1–2 letters, tinted background hashed from the name). Monogram renders first; the fetched image swaps in when available. Fetch failures are silent.

## 3. Behaviour unchanged
- All state comes from `DaemonClient` (status stream, optimistic toggle overlay, ordered commands). No new protocol commands. `servers.update` already supports name/command/args/env/url/auth; **headers is not updatable yet** — inspector shows headers read-only for now (note in UI) unless the protocol gains it (out of scope).

## 4. Testing
- `SmartPasteParser` (in `MCPMCore`) — table-driven tests: URL, command line with quotes, JSON in the three shapes, invalid input.
- `IconSource.resolve(server) -> .bundled(name) | .favicon(host) | .monogram(text, hue)` — pure, tested.
- Views: build must succeed with zero warnings; manual smoke against the running daemon.
