# Releasing MCP Manager

Tagging `vX.Y.Z` runs `.github/workflows/release.yml`, which builds the app, signs it with a
Developer ID certificate, notarizes and staples it, wraps it in a DMG, attaches the DMG to a GitHub
release, and pushes an updated cask to `carltonaikins/homebrew-tap`. Everything below is the one
time setup that workflow depends on, plus what to check after a release.

## What ships

- Artifact: `MCPManager-<version>.dmg`, containing `MCPManager.app` and a link to `/Applications`.
- The app name inside the DMG is **`MCPManager.app`**, with no space. That is the product name in
  `Apps/MCPManager/project.yml` (`PRODUCT_NAME` defaults to the target name, `MCPManager`), and the
  cask's `app "MCPManager.app"` stanza has to match it exactly. The design spec §10 writes it as
  `MCP Manager.app`; the spec is wrong on this point. `CFBundleDisplayName` is "MCP Manager", so
  Finder still shows a space; only the bundle on disk does not.
- The daemon `mcpmd` rides inside the bundle at `Contents/MacOS/mcpmd`, and its LaunchAgent plist
  at `Contents/Library/LaunchAgents/co.charmtechnologies.mcpmd.plist`.

## Secrets

Five repository secrets, at **Settings → Secrets and variables → Actions → New repository secret**.

### `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`

The Developer ID Application certificate and its private key, as a base64 `.p12`.

1. In the [Apple Developer account](https://developer.apple.com/account/resources/certificates),
   create a **Developer ID Application** certificate if there is not one already (Certificates →
   `+` → Developer ID Application → upload a CSR from Keychain Access → Certificate Assistant →
   Request a Certificate From a Certificate Authority, saved to disk).
2. Download the `.cer` and double-click it so it lands in the login keychain.
3. In **Keychain Access → My Certificates**, find `Developer ID Application: <name> (<TEAMID>)`,
   expand it so the private key is included, right-click → **Export**, and save as
   `certificate.p12`. Set a password at the prompt; that password is `MACOS_CERT_PASSWORD`.
4. Base64 the file and copy it:

   ```
   base64 -i certificate.p12 | pbcopy
   ```

   Paste that as `MACOS_CERT_PASSWORD`'s companion secret, `MACOS_CERT_P12`. Delete the local
   `.p12` afterwards; it carries the private key.

The workflow imports it into a throwaway keychain in `$RUNNER_TEMP`, runs
`security set-key-partition-list` so `codesign` does not stall on a UI prompt, and deletes the
keychain in an `always()` step.

### `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

Credentials for `xcrun notarytool`.

- `APPLE_ID`: the Apple ID email on the developer account.
- `APPLE_TEAM_ID`: the ten-character Team ID, shown at the top right of the developer account page
  and in the certificate's common name.
- `APPLE_APP_PASSWORD`: an **app-specific password**, not the account password. Create one at
  [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords →
  `+`, name it something like "notarytool mcp-manager", and copy the `xxxx-xxxx-xxxx-xxxx` value.
  It is shown once.

To check the three of them before a release, from a Mac:

```
xcrun notarytool history --apple-id "<email>" --team-id "<TEAMID>" --password "<app-specific>"
```

### `TAP_GITHUB_TOKEN`

A token that can push to the Homebrew tap.

1. Create the repo **`carltonaikins/homebrew-tap`** (public, that name exactly, so that
   `brew install --cask carltonaikins/tap/mcp-manager` resolves). A `Casks/` directory is enough;
   the workflow creates it if it is missing.
2. Create a token that can write to it. Either a fine-grained personal access token scoped to that
   one repository with **Contents: Read and write**, or a classic token with `repo`. Fine-grained
   tokens expire, so put a reminder somewhere for the expiry date.
3. Save it as `TAP_GITHUB_TOKEN` in **this** repository's Actions secrets.

The workflow clones the tap with `x-access-token:$TAP_GITHUB_TOKEN`, copies
`Homebrew/mcp-manager.rb` from this repo over `Casks/mcp-manager.rb`, rewrites the `version` and
`sha256` lines, and pushes. `Homebrew/mcp-manager.rb` here is the source of truth for the cask, so
edit it here rather than in the tap.

## Cutting a release

1. Update `CHANGELOG.md`: rename the `Unreleased` heading to the version and today's date, and add
   a link at the bottom.
2. Commit, then tag and push:

   ```
   git tag -a v0.1.0 -m "MCP Manager 0.1.0"
   git push origin v0.1.0
   ```

3. Watch the **Release** workflow. Notarization is the slow step; `notarytool submit --wait`
   usually returns in a few minutes but can take longer when Apple is busy.
4. Verify from a clean Mac (or at least a different one):

   ```
   brew install --cask carltonaikins/tap/mcp-manager
   spctl --assess --type execute -vv /Applications/MCPManager.app
   ```

## Version numbers

The tag drives everything. The workflow strips the leading `v` and passes
`MARKETING_VERSION=<version> CURRENT_PROJECT_VERSION=<run number>` to `xcodebuild`.

`Apps/MCPManager/Sources/Info.plist` currently hardcodes `CFBundleShortVersionString` as `1.0` and
`CFBundleVersion` as `1` instead of referring to `$(MARKETING_VERSION)` and
`$(CURRENT_PROJECT_VERSION)`, so those build settings do not reach the bundle by themselves. The
workflow stamps both keys with `PlistBuddy` after the build and before signing, which covers it.
The tidier fix is to set them to the variables in `project.yml`'s `info.properties`; once that
happens the stamping step can go.

## Notes on the build

- The workflows use `xcodebuild -target MCPManager`, not `-scheme`. `project.yml` declares no
  scheme, so XcodeGen writes no shared scheme into the generated project and a `-scheme` build
  would depend on Xcode autocreating one on the runner.
- The build itself is unsigned (`CODE_SIGNING_ALLOWED=NO`); signing is a separate step so the
  nested `Contents/MacOS/mcpmd` can be signed first. Signing the outer bundle before the binaries
  inside it invalidates the outer signature.
- Hardened runtime is on (`--options runtime`, and `ENABLE_HARDENED_RUNTIME: YES` in
  `project.yml`), which notarization requires. Every signature is timestamped (`--timestamp`).
- There is no entitlements file in the project today, so `codesign` is called without
  `--entitlements`. If one is added later (a Keychain access group shared between the app and the
  daemon is the likely reason), pass it on both `codesign` calls.
- The DMG is built by `scripts/make-dmg.sh` with `hdiutil` only, no `create-dmg` and no other
  Homebrew dependency. It is signed as well, then notarized and stapled, so a download that never
  reaches Apple's servers still passes Gatekeeper.

## If notarization fails

`notarytool submit --wait` prints a submission ID on failure. Ask for the log:

```
xcrun notarytool log <submission-id> --apple-id "<email>" --team-id "<TEAMID>" --password "<app-specific>"
```

The usual causes are a binary inside the bundle that was not signed (check `mcpmd`), a signature
without a secure timestamp, or hardened runtime missing on one of the two signatures.
