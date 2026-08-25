#!/bin/bash
# Records the screenshots and mini demos for mcpmanager.space, one prompt at a time.
#
# Run it from the repo root in Terminal (Terminal needs Screen Recording permission:
# System Settings → Privacy & Security → Screen Recording). You drive the mouse;
# each recording stops when you press Ctrl+C in the terminal — er, no: press any key?
# `screencapture -v` stops when you click its menu bar icon or press Cmd+Ctrl+Esc.
#
# Everything lands in site/assets/ and docs/img/, sized and compressed for the site.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p site/assets docs/img /tmp/mcpm-media

shot() { # name, instructions
  echo; echo "── $1 ──"; echo "$2"
  echo "Press Return, then click the window to capture (Esc to skip)."
  read -r
  screencapture -o -W "/tmp/mcpm-media/$1.png" || { echo "skipped"; return 0; }
  [ -f "/tmp/mcpm-media/$1.png" ] || { echo "skipped"; return 0; }
  cp "/tmp/mcpm-media/$1.png" "docs/img/$1.png"
  sips -Z 2320 "/tmp/mcpm-media/$1.png" --out "site/assets/$1.png" >/dev/null
  echo "✓ $1.png"
}

demo() { # name, seconds, instructions
  echo; echo "── $1 (~$2s) ──"; echo "$3"
  echo "Press Return to start recording; STOP with Cmd+Ctrl+Esc (or the ⏺ menu bar icon)."
  read -r
  screencapture -v "/tmp/mcpm-media/$1.mov" || { echo "skipped"; return 0; }
  [ -f "/tmp/mcpm-media/$1.mov" ] || { echo "skipped"; return 0; }
  if command -v ffmpeg >/dev/null; then
    ffmpeg -y -loglevel error -i "/tmp/mcpm-media/$1.mov" \
      -vf "scale='min(1600,iw)':-2,fps=30" -an -c:v libx264 -preset slow -crf 26 \
      -movflags +faststart "site/assets/$1.mp4"
  else
    cp "/tmp/mcpm-media/$1.mov" "site/assets/$1.mp4"   # unoptimized fallback
  fi
  echo "✓ $1.mp4 ($(du -h "site/assets/$1.mp4" | cut -f1))"
}

echo "Get the MCP Manager window ready (light or dark, your call — the site is white, light reads best)."

shot grid     "Main window on the Servers tab, a server selected so the inspector shows."
shot popover  "Open the menu bar popover, then capture it (click the popover)."
demo demo-library 12 "Servers tab: toggle a server ON for a client, pause a beat, toggle it back. Ideally with the client's config file visible in a terminal beside it."
demo demo-signin  15 "A signed-out OAuth server (use Sign out first if needed): click Sign in…, approve in the browser, come back to the green connected pill, click Test."
demo demo-catalog 12 "Catalog tab: search a server (e.g. posthog), click Add, show the pre-filled sheet, add it."

echo; echo "Done. Review site/assets/, then tell Claude to deploy."
