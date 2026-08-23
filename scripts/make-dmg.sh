#!/usr/bin/env bash
# Build a compressed DMG containing the app and a link to /Applications.
# Nothing here needs anything that is not already on a stock macOS runner.
#
#   scripts/make-dmg.sh <path-to-.app> <version> <output.dmg>
set -euo pipefail

APP=${1:?usage: make-dmg.sh <app> <version> <output.dmg>}
VERSION=${2:?usage: make-dmg.sh <app> <version> <output.dmg>}
OUTPUT=${3:?usage: make-dmg.sh <app> <version> <output.dmg>}

if [ ! -d "$APP" ]; then
  echo "make-dmg: no app bundle at $APP" >&2
  exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# -R keeps symlinks and the bundle's permission bits, which the signature depends on.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

# No -fs: the host default is right on both ends, and macOS 26 refuses to create HFS+ images.
hdiutil create \
  -volname "MCP Manager $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -ov \
  "$OUTPUT"

echo "make-dmg: wrote $OUTPUT"
