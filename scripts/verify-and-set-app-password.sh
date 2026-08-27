#!/bin/bash
# Verifies an app-specific password against Apple, then stores exactly that value
# as the APPLE_APP_PASSWORD secret. Nothing is stored unless Apple says yes first.
set -euo pipefail
cd "$(dirname "$0")/.."

APPLE_ID="caikins317@gmail.com"
TEAM_ID="FY9QB79VAP"

printf "App-specific password for %s: " "$APPLE_ID"
read -rs PW; echo

echo "Checking with Apple…"
if xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PW" >/dev/null 2>&1; then
  printf '%s' "$PW" | gh secret set APPLE_APP_PASSWORD
  echo "✓ Apple accepted it, and it is now stored as APPLE_APP_PASSWORD."
  echo "  Re-run the release workflow to pick it up."
else
  echo "✗ Apple rejected that password. Nothing was stored."
  echo "  Generate a fresh one at https://appleid.apple.com while signed in as $APPLE_ID"
  echo "  (Sign-In and Security → App-Specific Passwords), then run this again."
fi
unset PW
