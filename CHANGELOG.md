# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

First release. Everything below is new.

### Added

- **Server library.** `~/.mcpm/servers.json` is the single source of truth for every MCP server,
  written atomically and never containing a secret.
- **Client adapters** for Claude Code (`~/.claude.json`), Claude Desktop, Cursor
  (`~/.cursor/mcp.json`) and Codex (`~/.codex/config.toml`). Only the MCP section of a file is
  rewritten; the rest is preserved byte-for-byte, including TOML comments.
- **Sync engine** with the conflict rule "library wins on shape, client wins on presence": editing
  a server in the app updates every client it is enabled in, while adding or removing one by hand
  in a client's config flips that client's checkbox.
- **File watching and import.** Client configs are watched, outside edits are imported into the
  library, and each file is backed up to `~/.mcpm/backups/<client>/` before every write.
- **First-run onboarding.** The app shows what it found across the installed clients and what the
  first import would change. Until that is confirmed the daemon runs read-only: it reads every
  client and plans a sync, but saves nothing and writes no file.
- **Settings in `~/.mcpm/settings.json`:** `gatewayPort` (default 7337), `backupRetention`
  (default 5) and `importConfirmed`. Unknown and missing keys are tolerated on read, and
  `MCPM_GATEWAY_PORT` outranks the file.
- **Transport recorded per remote server**, `http` (streamable HTTP) or `sse`, and carried into
  every client config rather than guessed. A client pointed at the wrong one just fails to
  connect.
- **`mcpmd` daemon**, shipped inside the app bundle and installed as a LaunchAgent
  (`co.charmtechnologies.mcpmd`) through `SMAppService`, with a JSON-over-Unix-socket control API
  on `~/.mcpm/mcpmd.sock` (mode 0600, peer UID checked) and an app/daemon version handshake.
- **Menu bar app.** Popover with active-server, installed-client and needs-attention counts, a
  master toggle per server and an inline sign-in button for servers that need one.
- **Main window** built as a card grid with a pinned inspector. Each card shows the server, its
  transport and a chip per client, and clicking a chip toggles that server in that client without
  opening anything.
- **Smart-paste Add sheet.** One paste of a URL, an `npx …` command line or the JSON block out of a
  README fills in the form; the fields almost nobody touches sit behind Advanced. Server icons come
  from a bundled symbol, the site's favicon or a monogram.
- **Auth gateway** on `127.0.0.1:7337` (Hummingbird). Servers with `auth: oauth` or `auth: header`
  are written to clients as `http://127.0.0.1:7337/s/<id>/mcp`; the gateway proxies upstream with
  streaming and SSE passthrough, forwards `Mcp-Session-Id` untouched, strips any client-sent
  `Authorization`, and never logs bodies.
- **OAuth sign-in** per the MCP spec: protected-resource and authorization-server metadata
  discovery, dynamic client registration, PKCE S256 with a single-use short-lived `state`, RFC 8707
  `resource`, proactive refresh, one 401-refresh-retry, and revocation on sign-out. Tokens and
  header credentials live in the Keychain; `MCPM_TOKEN_STORE=file` swaps in a file store for
  development.
- **Test connection** for any server: stdio servers are spawned and given an MCP `initialize`,
  remote servers are probed through the gateway, and the result reports the server name, version
  and tool count.
- **Launch at login**, registered with `SMAppService` and toggled in Settings, alongside reinstall
  and restart of the background service.

### Known issues

- A running Claude Code session rewrites `~/.claude.json` from memory and can undo a write made
  while it is open. mcpm reads that as the user removing the server and turns the checkbox off;
  restart Claude Code and re-enable it.

[0.1.0]: https://github.com/carltonaikins/mcp-manager/releases/tag/v0.1.0
