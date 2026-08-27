# About MCP Manager

MCP Manager is a menu bar app for macOS. It keeps one library of MCP servers and writes the config file for every MCP client on your Mac.

## Why it exists

You add an MCP server to Claude Code. Then you want the same server in Cursor, so you open a second file and paste it again. Then Claude Desktop, which wants a different shape. Then Codex, which is TOML instead of JSON. Four files, four formats, and the day a token rotates you get to do the whole round trip again.

That is the entire problem this app solves. Add a server once, tick the clients that should have it, and MCP Manager writes each client's own file in that client's own format. It copies every file before it touches it, and it imports the servers you already have instead of asking you to start over.

## What it does

- One library of servers, with a checkbox per client on each one.
- Writes config for Claude Code, Claude Desktop, Cursor and Codex.
- One OAuth sign-in per remote server, shared by all four clients. A gateway on `127.0.0.1:7337` attaches the token on the way out and refreshes it before it expires, so you sign in to Notion or PostHog once instead of four times.
- Search the official MCP registry from inside the app, or paste a URL, a command, or the JSON blob out of somebody's README. The endpoint gets validated and the auth type detected for you.
- Test a server before you trust it. The app opens a session, lists what the server offers, and tells you what came back.

## How it is built

Swift, top to bottom. A SwiftUI menu bar app talks to a small background daemon called `mcpmd` over a Unix domain socket, and the daemon owns the library, the config writes and the gateway. Everything runs on your machine. There is no MCP Manager account, no server of ours in the path, and no telemetry in the app.

It is MIT licensed and the whole thing is on GitHub, so you can read it before you run it.

## What it is not

It is not a hosted service and it has no public API. `mcpmanager.space` is a marketing site: it describes the app, and the app itself is what you install. The gateway the app runs binds the loopback interface only, so nothing on the internet can reach it.

## Who made it

Carlton Aikins, under Charm Technologies. Bugs, questions and feature requests all go to [GitHub issues](https://github.com/31Carlton7/mcp-manager/issues).

## Links

- [Download the latest release](https://github.com/31Carlton7/mcp-manager/releases/latest)
- [Source on GitHub](https://github.com/31Carlton7/mcp-manager)
- [Contact](https://mcpmanager.space/contact)
- [Privacy](https://mcpmanager.space/privacy)
