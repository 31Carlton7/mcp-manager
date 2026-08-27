# Releasing MCP Manager

Tagging `vX.Y.Z` runs `.github/workflows/release.yml`, which builds the app, signs it with a
Developer ID certificate, notarizes and staples it, wraps it in a DMG, attaches the DMG to a GitHub
release, and pushes an updated cask to `31Carlton7/homebrew-tap`. Everything below is the one
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

Six repository secrets, at **Settings → Secrets and variables → Actions → New repository secret**.

`scripts/set-signing-secrets.sh` sets three of them (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` and
`APPLE_APP_PASSWORD`) from a Mac that already holds the certificate, and
`scripts/verify-and-set-app-password.sh` checks an app-specific password against Apple before
storing it. `APPLE_ID`, `APPLE_TEAM_ID` and `TAP_DEPLOY_KEY` you set yourself.

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

### `TAP_DEPLOY_KEY`

An SSH deploy key that can push to the Homebrew tap. A deploy key rather than a personal access
token: it reaches that one repository and nothing else, and it does not expire out from under a
release.

1. Create the repo **`31Carlton7/homebrew-tap`** (public, that name exactly, so that
   `brew install --cask 31carlton7/tap/mcp-manager` resolves). A `Casks/` directory is enough;
   the workflow creates it if it is missing.
2. Generate a key pair: `ssh-keygen -t ed25519 -N "" -f tapkey`.
3. Add `tapkey.pub` under the tap's **Settings → Deploy keys**, with "Allow write access" ticked.
4. Store the private half on **this** repository: `gh secret set TAP_DEPLOY_KEY < tapkey`. Delete
   both local files afterwards.

The workflow writes the key into `$RUNNER_TEMP`, clones the tap over SSH, copies
`Homebrew/mcp-manager.rb` from this repo over `Casks/mcp-manager.rb`, rewrites the `version` and
`sha256` lines, and pushes. `Homebrew/mcp-manager.rb` here is the source of truth for the cask, so
edit it here rather than in the tap.

## Cutting a release

1. Bump `MCPMVersion.current` in `Sources/MCPMCore/Version.swift` and `MARKETING_VERSION` in
   `Apps/MCPManager/project.yml` to the version you are about to tag.
2. Update `CHANGELOG.md`: add a section for the version with today's date, and a link at the
   bottom.
3. Commit, then tag and push:

   ```
   git tag -a v0.1.0 -m "MCP Manager 0.1.0"
   git push origin v0.1.0
   ```

4. Watch the **Release** workflow. It runs the suite in debug and in release before it builds, so
   a failing test stops the release instead of shipping past it. Notarization is the slow step;
   `notarytool submit --wait` usually returns in a few minutes but can take longer when Apple is
   busy.
5. Verify from a clean Mac (or at least a different one):

   ```
   brew install --cask 31carlton7/tap/mcp-manager
   spctl --assess --type execute -vv /Applications/MCPManager.app
   ```

## Version numbers

`Sources/MCPMCore/Version.swift` holds the version. **The tag has to match it**: the workflow reads
`MCPMVersion.current` and fails before it builds anything if `v<version>` and that string disagree.
The daemon reports `MCPMVersion.current`, so a mismatch would ship a bundle whose version is not
the one on the release. Bump `Version.swift` (and `MARKETING_VERSION` in `project.yml` with it),
commit, then tag.

Past that check the tag drives the build: the workflow strips the leading `v` and passes
`MARKETING_VERSION=<version> CURRENT_PROJECT_VERSION=<run number>` to `xcodebuild`. `project.yml`
resolves `CFBundleShortVersionString` from `$(MARKETING_VERSION)` and `CFBundleVersion` from
`$(CURRENT_PROJECT_VERSION)`, so those reach the built bundle. The workflow reads
`CFBundleShortVersionString` back out of the built app and fails if it is not the tag's version.

## Notes on the build

- `project.yml` declares a shared `MCPManager` scheme, so the workflows and the README build with
  `xcodebuild -scheme MCPManager` (Xcode 26 requires a scheme when `-derivedDataPath` is used).
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
  reaches Apple's servers still passes Gatekeeper. The script passes no `-fs`, so `hdiutil` picks
  the host default: macOS 26 refuses to create HFS+ images, and pinning a filesystem would break
  the script on one end or the other.
- Only the DMG is notarized and stapled, not the `.app` inside it. Stapling the app too means a
  second notarization round trip (zip the app, submit, staple, then build and submit the DMG), and
  the ticket on the DMG already covers the first launch of the app copied out of it. Worth
  revisiting if anyone reports a Gatekeeper prompt offline.

## If notarization fails

`notarytool submit --wait` prints a submission ID on failure. Ask for the log:

```
xcrun notarytool log <submission-id> --apple-id "<email>" --team-id "<TEAMID>" --password "<app-specific>"
```

The usual causes are a binary inside the bundle that was not signed (check `mcpmd`), a signature
without a secure timestamp, or hardened runtime missing on one of the two signatures.

## Checking the tap credential

To confirm `TAP_DEPLOY_KEY` still works without cutting a release:

```
gh workflow run verify-tap-access.yml
```

It clones the tap and asks the server whether a push would be accepted, writing nothing. Rotating
the key is the same four steps as creating it, above.
