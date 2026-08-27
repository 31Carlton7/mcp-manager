#!/bin/bash
# Sets the code-signing secrets the release workflow needs. Every value is read from the terminal
# or the keychain and piped straight into `gh secret set`: nothing is echoed, and the only file
# written is a temporary .p12 that the EXIT trap removes.
#
# TAP_DEPLOY_KEY is not set here: see "Checking the tap credential" in docs/RELEASING.md.
#
#   ./scripts/set-signing-secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Carlton Aikins (FY9QB79VAP)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "1/2  Exporting $IDENTITY"
echo "     macOS will ask permission to read the private key, and you'll pick an"
echo "     export password. Use anything; it only has to match what you type next."
security export -t identities -f pkcs12 -o "$TMP/cert.p12" \
  -T /usr/bin/codesign 2>/dev/null || {
    echo "     (falling back to an interactive export — pick the Developer ID identity)"
    security export -t identities -f pkcs12 -o "$TMP/cert.p12"
  }
base64 -i "$TMP/cert.p12" | gh secret set MACOS_CERT_P12
echo "     ✓ MACOS_CERT_P12"

printf "     Re-enter that same export password: "
read -rs P12PASS; echo
printf '%s' "$P12PASS" | gh secret set MACOS_CERT_PASSWORD
unset P12PASS
echo "     ✓ MACOS_CERT_PASSWORD"

echo
echo "2/2  App-specific password for notarization"
echo "     Make one at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords"
printf "     Paste it here (format abcd-efgh-ijkl-mnop): "
read -rs APPPASS; echo
printf '%s' "$APPPASS" | gh secret set APPLE_APP_PASSWORD
unset APPPASS
echo "     ✓ APPLE_APP_PASSWORD"

echo
echo "All set. Secrets now on the repo:"
gh secret list
