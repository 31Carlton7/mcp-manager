#!/bin/bash
# Renders every image and clip on mcpmanager.space out of the app itself.
#
# There is no Screen Recording permission anywhere in this project, so nothing here photographs the
# screen: the app draws its own window into a bitmap (`NSView.cacheDisplay`, see
# Apps/MCPManager/Sources/DemoCapture.swift) and writes the frames out. This script only stages the
# world that app sees, starts it, and hands the frames to ffmpeg.
#
# The world is a scratch home under /private/tmp: the real ~/.mcpm/servers.json is copied in so the
# grid shows real servers, but the daemon and the app both run with HOME pointed there, on their own
# socket and their own gateway port. The copy that is actually installed — app, daemon, login item,
# client configs — is never touched, and this script kills nothing it did not start itself.
#
#   scripts/render-site-media.sh
#
# Leave the Mac alone while it runs (about two minutes): the app has to stay frontmost, since an
# inactive window draws its controls in the inactive grey.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

FFMPEG=/opt/homebrew/bin/ffmpeg
SCRATCH=/private/tmp/mcpm-demo          # short: the control socket lives under it and sun_path is 104
HOME_DIR="$SCRATCH/home"
OUT="$SCRATCH/out"
GATEWAY_PORT=17440                      # not 7337 — the real daemon has that
APP="$REPO/Apps/MCPManager/build/Build/Products/Debug/MCPManager.app"

command -v "$FFMPEG" >/dev/null || { echo "ffmpeg not found at $FFMPEG" >&2; exit 1; }
[ -f "$HOME/.mcpm/servers.json" ] || { echo "no ~/.mcpm/servers.json to copy from" >&2; exit 1; }

# ---------------------------------------------------------------- build

echo "── building"
swift build --product mcpmd
( cd Apps/MCPManager && xcodegen generate -q && \
  xcodebuild -scheme MCPManager -configuration Debug -derivedDataPath build build >/dev/null )
[ -x "$APP/Contents/MacOS/MCPManager" ] || { echo "no app at $APP" >&2; exit 1; }

# ---------------------------------------------------------------- scratch world

echo "── staging $SCRATCH"
rm -rf "$SCRATCH"
mkdir -p "$HOME_DIR/.mcpm" "$OUT" "$HOME_DIR/.claude" "$HOME_DIR/.cursor" "$HOME_DIR/.codex" \
         "$HOME_DIR/Library/Application Support/Claude"

# The library, minus the throwaway server every developer's real one has in it.
python3 - "$HOME/.mcpm/servers.json" "$HOME_DIR/.mcpm/servers.json" <<'PY'
import json, sys
library = json.load(open(sys.argv[1]))
library["servers"] = [s for s in library["servers"] if s["id"] != "smoke-test"]
json.dump(library, open(sys.argv[2], "w"), indent=1, sort_keys=True)
PY

cat > "$HOME_DIR/.mcpm/settings.json" <<EOF
{
  "backupRetention" : 5,
  "gatewayPort" : $GATEWAY_PORT,
  "importConfirmed" : true
}
EOF

# Every supported client, so the cards show four chips and the popover counts four clients. These
# are the files the scratch daemon syncs to; the real ones are in the real home and out of reach.
#
# They are written with the servers the library says are on for each client, because that is what a
# real install looks like from the daemon's side: a server the library has on for a client but that
# is missing from that client's file is one the user deleted by hand, and the first sync would
# faithfully turn it off. The bodies only have to be recognisable — the sync matches on the name
# first and rewrites each file properly on its first pass.
python3 - "$HOME_DIR" <<'PY'
import json, os, sys
home = sys.argv[1]
library = json.load(open(os.path.join(home, ".mcpm/servers.json")))["servers"]

def entry(server, bridge_remote=False):
    if server["kind"] == "remote":
        if bridge_remote:                      # Claude Desktop speaks stdio only
            return {"command": "npx", "args": ["-y", "mcp-remote", server["url"]]}
        return {"url": server["url"]}
    return {"command": server["command"], "args": server.get("args", [])}

def enabled(client):
    return [s for s in library if s["clients"].get(client)]

def write_json(path, client, bridge_remote=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    servers = {s["name"]: entry(s, bridge_remote) for s in enabled(client)}
    json.dump({"mcpServers": servers}, open(path, "w"), indent=2)

write_json(os.path.join(home, ".claude.json"), "claude-code")
write_json(os.path.join(home, ".cursor/mcp.json"), "cursor")
write_json(os.path.join(home, "Library/Application Support/Claude/claude_desktop_config.json"),
           "claude-desktop", bridge_remote=True)

lines = []
for server in enabled("codex"):
    lines.append('[mcp_servers."%s"]' % server["name"])
    fields = entry(server)
    for key, value in fields.items():
        lines.append("%s = %s" % (key, json.dumps(value)))
    lines.append("")
open(os.path.join(home, ".codex/config.toml"), "w").write("\n".join(lines))
PY

# Credentials for the scratch FileTokenStore (the shape in Sources/MCPMGateway/Tokens/TokenStore.swift):
# notion is signed in from the start, and posthog's record is staged beside the live file for the
# sign-in clip to drop into place.
cat > "$HOME_DIR/.mcpm/tokens.json" <<'EOF'
{
  "headers" : {},
  "registrations" : {},
  "tokens" : {
    "notion" : {
      "accessToken" : "demo-access-token",
      "clientID" : "demo-client",
      "expiresAt" : "2027-06-01T00:00:00Z",
      "refreshToken" : "demo-refresh-token",
      "tokenEndpoint" : "https://mcp.notion.com/token",
      "tokenType" : "Bearer"
    }
  }
}
EOF
python3 - "$HOME_DIR/.mcpm/tokens.json" "$HOME_DIR/.mcpm/tokens.signed-in.json" <<'PY'
import json, sys
store = json.load(open(sys.argv[1]))
store["tokens"]["posthog"] = dict(store["tokens"]["notion"],
                                  tokenEndpoint="https://mcp.posthog.com/token")
json.dump(store, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
chmod 600 "$HOME_DIR/.mcpm/tokens.json" "$HOME_DIR/.mcpm/tokens.signed-in.json"

# ---------------------------------------------------------------- run

# Only ever the two processes this script started. The user's own app and daemon are running right
# now and must survive this untouched.
cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

app_pids() { pgrep -f "MCPManager.app/Contents/MacOS/MCPManager" | sort; }

echo "── starting the scratch daemon"
HOME="$HOME_DIR" MCPM_TOKEN_STORE=file MCPM_GATEWAY_PORT="$GATEWAY_PORT" \
  "$REPO/.build/debug/mcpmd" > "$SCRATCH/mcpmd.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do [ -S "$HOME_DIR/.mcpm/mcpmd.sock" ] && break; sleep 0.2; done
[ -S "$HOME_DIR/.mcpm/mcpmd.sock" ] || { echo "the scratch daemon never listened; see $SCRATCH/mcpmd.log" >&2; exit 1; }

echo "── running the app in capture mode (leave the Mac alone)"
# Through `open`, so LaunchServices activates it: a window that never becomes key draws every accent
# grey. `-n` gets its own instance beside the one the user is running, `--env` is what carries the
# scratch home in, and the argument domain suppresses the login-item nudge without writing to the
# real app's preferences.
BEFORE=$(app_pids || true)
open -n "$APP" --env "HOME=$HOME_DIR" --env "MCPM_DEMO_CAPTURE=$OUT" \
     --env "MCPM_TOKEN_STORE=file" --args -dismissedStartupNudge YES
sleep 3
# The one pid that wasn't there a moment ago — never whichever instance the user already had open.
APP_PID=$(comm -13 <(echo "$BEFORE") <(app_pids || true) | head -1)

for _ in $(seq 1 200); do
  [ -f "$OUT/done" ] && break
  [ -f "$OUT/error" ] && { echo "capture failed: $(cat "$OUT/error")" >&2; exit 1; }
  sleep 1
done
[ -f "$OUT/done" ] || { echo "the app never finished; see $SCRATCH/mcpmd.log" >&2; exit 1; }

cleanup
trap - EXIT

# ---------------------------------------------------------------- encode

mkdir -p site/assets docs/img

for name in grid popover; do
  [ -f "$OUT/$name.png" ] || { echo "missing $name.png" >&2; exit 1; }
  cp "$OUT/$name.png" "docs/img/$name.png"
  sips -Z 2320 "$OUT/$name.png" --out "site/assets/$name.png" >/dev/null
  echo "✓ $name.png ($(sips -g pixelWidth -g pixelHeight "site/assets/$name.png" | awk '/pixel/{printf "%s ", $2}'))"
done

for name in demo-library demo-signin demo-catalog; do
  frames="$OUT/frames-$name"
  count=$(ls "$frames"/f*.jpg 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 30 ] || { echo "only $count frames for $name" >&2; exit 1; }
  fps=$(cat "$frames/fps")
  "$FFMPEG" -y -loglevel error -framerate "$fps" -i "$frames/f%05d.jpg" \
    -vf "scale='min(1600,iw)':-2" -an -c:v libx264 -preset slow -crf 26 \
    -pix_fmt yuv420p -movflags +faststart "site/assets/$name.mp4"
  echo "✓ $name.mp4 ($count frames at ${fps%.*} fps, $(du -h "site/assets/$name.mp4" | cut -f1))"
done

echo
echo "Done. site/assets/ and docs/img/ are up to date; the scratch world is still at $SCRATCH."
