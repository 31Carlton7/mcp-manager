# Privacy

Short version: this website has no analytics and no cookies, and the app has no account and no telemetry. Nothing you do in MCP Manager is reported anywhere.

The long version is below, because "we respect your privacy" is worth nothing without the specifics.

## This website

`mcpmanager.space` is a handful of static files. There is no analytics script, no tag manager, no pixel, no A/B testing, no cookie banner, because there are no cookies to warn you about. The page sets nothing in your browser's storage and there is no JavaScript on it beyond a copy-to-clipboard button.

Two things are worth naming anyway, because they are true:

- The page loads its typeface from Google Fonts (`fonts.googleapis.com` and `fonts.gstatic.com`). That request goes to Google, and Google can see your IP address and user agent when it happens.
- The site is hosted on Vercel, which keeps ordinary server request logs the way every host does. Those logs are Vercel's, they are not read for any product purpose, and there is nothing in them beyond what any web server records.

No form on this site asks you for anything, so there is nothing to submit and no mailing list to end up on.

## The app

MCP Manager runs entirely on your Mac. There is no MCP Manager account, no sign-in to us, no server of ours anywhere in the path, and no crash reporter, analytics SDK or update checker built into the app.

Where your data lives:

- Your server library, settings and config backups sit in `~/.mcpm` on your own disk.
- OAuth tokens go in the macOS Keychain. They are never written into a client's config file and never into the library file.
- The gateway that shares one sign-in across your clients binds `127.0.0.1` and nothing else, on port 7337 by default. It is not reachable from your network or from the internet, and it rejects requests whose Host header is not a loopback name.
- Every config file is copied before it is written, so an import you did not want can be undone from the backup.

## What the app connects to

The app makes network requests, but only ones you asked for:

- The MCP servers in your own library, when a client uses them or when you press Test.
- `registry.modelcontextprotocol.io`, when you search the official registry from the catalog.
- The website of a server's vendor, to fetch that server's favicon for the list.

That is the whole list. Nothing is sent to Charm Technologies, because there is nothing on our end to send it to.

## Your rights

There is no personal data to request, correct or delete, because none is collected. If you want the app's local data gone, `brew uninstall --zap --cask mcp-manager` removes `~/.mcpm` and the app's cache. Tokens in the Keychain are separate: delete those in Keychain Access.

## Changes

If this ever changes, it changes in a commit you can read, in a public repository, along with the code that made it change.

Questions about any of this go to [GitHub issues](https://github.com/31Carlton7/mcp-manager/issues).

Last updated 27 August 2026.
