# MCP Manager

> Every MCP server, every client, one menu bar app. Add a server once, toggle it on for Claude Code, Claude Desktop, Cursor or Codex, and the config files get written for you.

MCP Manager is a free, MIT licensed macOS app. Current version 0.1.2. Requires macOS 26 or later.

- Download: <https://github.com/31Carlton7/mcp-manager/releases/latest>
- Homebrew: `brew install --cask 31carlton7/tap/mcp-manager`
- Source: <https://github.com/31Carlton7/mcp-manager>

## What MCP Manager does

**One library, four config files.** Add a server once and tick the clients that should have it. MCP Manager writes each client's own config file and copies it first, so a server can be on in Claude Code and off in Cursor without you editing anything by hand.

**One library, every client.** Claude Code, Claude Desktop, Cursor and Codex read the files MCP Manager writes. It imports the servers you already have, backs up each file before it touches it, and changes nothing until you confirm the first import.

**Sign in once to remote servers.** Notion, PostHog, anything with OAuth. A gateway on `127.0.0.1` injects the token on the way out and refreshes it before it expires, so all four clients share one sign-in. Tokens live in the Keychain.

**Find it, add it, test it.** Search the official MCP registry in the app and add from the catalog, or paste any URL, command or README JSON, and the endpoint is validated and the auth type detected for you. Test any server's connection before you trust it.

## Credentials stay on the machine

The gateway binds `127.0.0.1` and nothing else. Tokens are kept in the Keychain, never in a client's config file and never in the library. Every write is backed up first, and it is MIT licensed, so you can read all of it before you run it.

## Install

```
brew install --cask 31carlton7/tap/mcp-manager
```

Or download the dmg from the [latest release](https://github.com/31Carlton7/mcp-manager/releases/latest).

## More

- [About](https://mcpmanager.space/about)
- [Contact](https://mcpmanager.space/contact)
- [Privacy](https://mcpmanager.space/privacy)
- [llms.txt](https://mcpmanager.space/llms.txt)

MCP Manager is free and MIT licensed, made by [Carlton Aikins](https://carltonaikins.com).
