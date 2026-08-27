#!/bin/bash
# Renders every image and clip on mcpmanager.space out of the app itself.
#
#   scripts/render-site-media.sh
#
# Nothing here photographs the screen: the project holds no Screen Recording permission, so the app
# draws its own window into a bitmap (Apps/MCPManager/Sources/DemoCapture.swift). This script stages
# the world that app sees, starts it, and hands the frames to ffmpeg.
#
# That world is a scratch HOME under /private/tmp, on its own socket and gateway port. The installed
# copy (app, daemon, login item, client configs) is never touched, and only the two processes this
# script started are ever killed.
#
# Leave the Mac alone while it runs (about two minutes), and leave it unlocked: an app that is not
# frontmost draws its controls in the inactive grey and never animates the inspector open. Behind
# the lock screen the run fails instead of writing assets that look almost right.
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

echo "── building"
swift build --product mcpmd
( cd Apps/MCPManager && xcodegen generate -q && \
  xcodebuild -scheme MCPManager -configuration Debug -derivedDataPath build build >/dev/null )
[ -x "$APP/Contents/MacOS/MCPManager" ] || { echo "no app at $APP" >&2; exit 1; }

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

# Every supported client, so the cards show four chips and the popover counts four clients.
#
# Each file is seeded with the servers the library says are on for that client: a server the library
# has on but that is missing from the client's file reads as one the user deleted by hand, and the
# first sync would faithfully turn it off. The bodies only have to be recognisable, since the sync
# matches on name and rewrites each file properly on its first pass.
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
# notion is signed in, which is what the stills show, and posthog is not, which is its real state.
# Two more copies are staged beside the live file — one without notion and one with it — and the
# sign-in clip moves between them: it signs notion out, films the wait, and signs it back in.
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
python3 - "$HOME_DIR/.mcpm" <<'PY'
import json, os, sys
root = sys.argv[1]
store = json.load(open(os.path.join(root, "tokens.json")))
json.dump(store, open(os.path.join(root, "tokens.signed-in.json"), "w"), indent=2, sort_keys=True)
json.dump(dict(store, tokens={}), open(os.path.join(root, "tokens.signed-out.json"), "w"),
          indent=2, sort_keys=True)
PY
chmod 600 "$HOME_DIR/.mcpm/tokens.json" "$HOME_DIR/.mcpm/tokens.signed-in.json" \
          "$HOME_DIR/.mcpm/tokens.signed-out.json"

# Only ever the two processes this script started: the user's own app and daemon must survive it.
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
