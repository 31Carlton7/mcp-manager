#!/bin/bash
# Sets the remaining GitHub secrets for the release workflow.
#
# Everything secret is read straight from your terminal (or your keychain) and piped
# into `gh secret set`. Nothing is printed, nothing is written to disk except one
# temporary .p12 that is shredded at the end.
#
#   ./scripts/set-signing-secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Carlton Aikins (FY9QB79VAP)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "1/3  Exporting $IDENTITY"
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
echo "2/3  App-specific password for notarization"
echo "     Make one at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords"
printf "     Paste it here (format abcd-efgh-ijkl-mnop): "
read -rs APPPASS; echo
printf '%s' "$APPPASS" | gh secret set APPLE_APP_PASSWORD
unset APPPASS
echo "     ✓ APPLE_APP_PASSWORD"

echo
echo "3/3  GitHub token that can push to 31Carlton7/homebrew-tap"
echo "     Make one at https://github.com/settings/tokens?type=beta"
echo "     (fine-grained, repo 31Carlton7/homebrew-tap, Contents: Read and write)"
printf "     Paste it here: "
read -rs TAPTOK; echo
printf '%s' "$TAPTOK" | gh secret set TAP_GITHUB_TOKEN
unset TAPTOK
echo "     ✓ TAP_GITHUB_TOKEN"

echo
echo "All set. Secrets now on the repo:"
gh secret list
