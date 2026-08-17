# MCP Manager

MCP Manager keeps one list of MCP servers and syncs it into the config files the clients on your
machine already read — Claude Code (`~/.claude.json`), Claude Desktop, Cursor (`~/.cursor/mcp.json`)
and Codex (`~/.codex/config.toml`). A background daemon owns the library, watches those files for
outside edits and imports anything it finds, and writes each client back with a checkbox per server.
A menu bar app talks to the daemon over a unix socket and is the only UI. Everything outside the
MCP section of a config file is left byte-for-byte alone, and each file is backed up before it is
overwritten.

## Status

Plan 1 — the config hub — is done: library, adapters for the four clients, file watching, backups,
the control protocol, the daemon and the app. Next: the local OAuth gateway (remote servers with
`auth` set are rejected until it exists) and packaging/launchd installation.

## UI

Clicking the menu bar icon opens a popover: three hero numbers across the top — how many servers
are active, how many clients are installed, how many things need a human — over a list of servers
with a switch each, and a second tab for the clients behind them. The main window is a grid of
server cards with an inspector pinned to the right; a card shows the server, its transport and a
chip per client, and clicking a chip turns that server on or off in that client without opening
anything. Add takes one paste — a URL, an `npx …` line, or the whole JSON block from a README — and
fills the rest of the form in itself, with the fields almost nobody touches behind Advanced.

## Build and run

Daemon:

```
swift build && .build/debug/mcpmd
```

App:

```
cd Apps/MCPManager
xcodegen generate
xcodebuild -project MCPManager.xcodeproj -scheme MCPManager -configuration Debug \
  -derivedDataPath build build
```

`xcodegen generate` writes the `.xcodeproj` (it is not checked in); after that you can open it in
Xcode instead of using `xcodebuild`. The app needs the daemon running — it reconnects on its own
if the daemon is restarted.

Tests: `swift test`.

## Where state lives

- `~/.mcpm/servers.json` — the library, the one file that is the source of truth.
- `~/.mcpm/backups/<client>/` — timestamped copies of each client config, last five kept.
- `~/.mcpm/mcpmd.sock` — the control socket the app connects to.

## Conflict rule

Library wins on shape, client wins on presence: the command, args, env, url and headers come from
the library, but whether a server appears in a given client's file is whatever that file last said.
So editing a server in the app changes it everywhere it is enabled, and adding or removing one by
hand in a client's own config flips that client's checkbox rather than being reverted.

## Caveat: Claude Code rewrites its config from memory

A running Claude Code session holds `~/.claude.json` in memory and rewrites the whole file when it
saves. If mcpm edits that file while a session is open, the session's next write can put its own
version back and undo the edit. Because presence is the client's to decide, mcpm reads that as the
user removing the server from Claude Code and turns the checkbox off. Restart Claude Code (or make
the change with no session running) and re-enable it.
