#!/bin/bash
# Cuts the launch video out of the clips scripts/render-site-media.sh already produced.
#
#   scripts/render-site-media.sh     # first, if the app's UI has changed
#   scripts/render-launch-video.sh
#
# Nothing here drives the app or records the screen: the three demo clips are the source footage,
# and this only composites them onto brand cards (scripts/launch-card.html, rendered by headless
# Chrome) and cross-fades the result. Safe to re-run while you use the Mac.
#
# The cut points below are frame-accurate against the current clips. If render-site-media.sh is
# re-run and its scenes drift, re-check them — a start time that lands a beat late shows the
# aftermath of an interaction instead of the interaction.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

FFMPEG=/opt/homebrew/bin/ffmpeg
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ASSETS="$REPO/site/assets"
WORK=$(mktemp -d /private/tmp/mcpm-launch.XXXXXX)
OUT="$ASSETS/launch.mp4"
trap 'rm -rf "$WORK"' EXIT

command -v "$FFMPEG" >/dev/null || { echo "ffmpeg not found at $FFMPEG" >&2; exit 1; }
[ -x "$CHROME" ] || { echo "Google Chrome not found; it renders the cards" >&2; exit 1; }
for clip in demo-library demo-catalog demo-signin; do
  [ -f "$ASSETS/$clip.mp4" ] || { echo "no $clip.mp4 — run scripts/render-site-media.sh first" >&2; exit 1; }
done

# The window sits at this rect on a 1600x900 canvas, in the card, in the mask, and in the overlay
# below. One definition, three consumers.
X=100; Y=52; W=1400; H=676
FADE=0.35                      # cross-fade between every pair of segments
FPS=30

echo "── rendering the cards"
sed "s|ASSETS|file://$ASSETS|g" scripts/launch-card.html > "$WORK/card.html"
card() {   # card <file> <query>
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=1600,900 --virtual-time-budget=6000 --allow-file-access-from-files \
    --screenshot="$WORK/$1" "file://$WORK/card.html?$2" >/dev/null 2>&1
  [ -s "$WORK/$1" ] || { echo "Chrome produced no $1" >&2; exit 1; }
}
urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

card title.png "card=title"
card end.png   "card=end"
card mask.png  "card=mask"

# name | source clip | start | duration | caption | sub
SHOTS=(
  "library|demo-library|2.0|2.8|One library. Every client.|Toggle a server on for Claude Code, Claude Desktop, Cursor or Codex."
  "catalog|demo-catalog|3.8|3.4|Add from the MCP registry|Search, add, and the auth it needs is detected for you."
  "signin|demo-signin|1.6|3.4|Sign in once|OAuth through a local gateway. Tokens stay in your Keychain."
)

echo "── cutting the segments"
still() {  # still <name> <png> <duration>
  "$FFMPEG" -v error -y -loop 1 -i "$WORK/$2" -t "$3" \
    -vf "fps=$FPS,format=yuv420p" -c:v libx264 -preset slow -crf 18 "$WORK/$1.mp4"
}
still seg0 title.png 2.2

i=1
for shot in "${SHOTS[@]}"; do
  IFS='|' read -r name clip start dur cap sub <<< "$shot"
  card "bg-$name.png" "card=shot&cap=$(urlencode "$cap")&sub=$(urlencode "$sub")"
  # The mask carries the rounded corners; the plate under it is already drawn in the card, so the
  # corners land on the plate rather than on a hard edge of footage.
  "$FFMPEG" -v error -y -loop 1 -i "$WORK/bg-$name.png" \
    -ss "$start" -t "$dur" -i "$ASSETS/$clip.mp4" -loop 1 -i "$WORK/mask.png" \
    -filter_complex "\
      [1:v]scale=$W:$H,setsar=1,fps=$FPS[v];\
      [2:v]crop=$W:$H:$X:$Y,format=gray[m];\
      [v][m]alphamerge[va];\
      [0:v]fps=$FPS[bg];\
      [bg][va]overlay=$X:$Y:shortest=1,format=yuv420p[out]" \
    -map "[out]" -t "$dur" -c:v libx264 -preset slow -crf 18 "$WORK/seg$i.mp4"
  echo "   seg$i  $name  ${start}s +${dur}s"
  i=$((i + 1))
done
still seg4 end.png 2.4

echo "── cross-fading"
# Each offset is where the *running* total meets the next segment, less one fade: a fade overlaps
# the two segments it joins rather than being added between them.
DURS=(2.2 2.8 3.4 3.4 2.4)
chain=""; prev="[0:v]"; total=${DURS[0]}
for n in 1 2 3 4; do
  offset=$(python3 -c "print(round($total - $FADE, 3))")
  label="[x$n]"
  [ "$n" = 4 ] && label="[out]"
  chain="$chain$prev[$n:v]xfade=transition=fade:duration=$FADE:offset=$offset$label;"
  prev="$label"
  total=$(python3 -c "print(round($total + ${DURS[$n]} - $FADE, 3))")
done

"$FFMPEG" -v error -y \
  -i "$WORK/seg0.mp4" -i "$WORK/seg1.mp4" -i "$WORK/seg2.mp4" -i "$WORK/seg3.mp4" -i "$WORK/seg4.mp4" \
  -filter_complex "${chain%;}" -map "[out]" \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$OUT"

echo
echo "✓ $(basename "$OUT")  $(${FFMPEG/ffmpeg/ffprobe} -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$OUT")  \
${total}s  $(du -h "$OUT" | cut -f1)"
