#!/bin/bash
# parity-shots.sh: render the popover through the app's own DEBUG hook (`-ShareBarShotsRender`),
# with no pointer or key input, for the design-parity check. Light and dark, calm list and the
# row menu open on the first row. The fake CLI answers from scenarios/parity-calm with dates
# relative to today, so the trailing ages read 1d, 3d and 8d on any day.
#
# Usage: mac/Tests/fixtures/popover/parity-shots.sh <out dir>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/../../.." && pwd)"
OUT="${1:?usage: parity-shots.sh <out dir>}"
WORK="$MAC/build/parity"
mkdir -p "$OUT" "$WORK"

APP_PID=""
cleanup() {
  if [[ -n $APP_PID ]]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

swift build --package-path "$MAC" >/dev/null
BIN="$(swift build --package-path "$MAC" --show-bin-path)"
APP="$WORK/Share Bar.app"
mkdir -p "$APP/Contents/MacOS"
cp -f "$BIN/ShareBar" "$APP/Contents/MacOS/ShareBar"
cp -f "$MAC/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.dwarves.sharebar.shots" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

RUN="$WORK/run"
mkdir -p "$WORK/gone"; mv "$RUN" "$WORK/gone/run.$$" 2>/dev/null || true
mkdir -p "$RUN/scenario"
command cp -f "$HERE/scenarios/parity-calm/member-ls.json" "$RUN/scenario/"
sed -e "s/@D1@/$(date -v-1d +%F)/" -e "s/@D3@/$(date -v-3d +%F)/" -e "s/@D8@/$(date -v-8d +%F)/" \
    -e "s/@EXP27@/$(( $(date +%s) + 27 * 86400 + 3600 ))/" \
    "$HERE/scenarios/parity-calm/profiles.json.tmpl" > "$RUN/scenario/profiles.json"
: > "$RUN/argv.log"

shoot() { # shoot <label> <light|dark> [menu row id]
  local label="$1" mode="$2" row="${3:-}" png="$OUT/$1-$2.png" args=()
  mkdir -p "$WORK/gone"; mv -f "$png" "$WORK/gone/$(basename "$png").$$" 2>/dev/null || true
  args=(-ShareBarShotsRender "$png")
  [[ $mode == dark ]] && args+=(-ShareBarShotsAppearance dark)
  [[ -n $row ]] && args+=(-ShareBarShotsMenuRow "$row")
  SHARE_BIN="$MAC/Tests/fixtures/bin/share" SHARE_FAKE_DIR="$RUN" SHARE_FAKE_DELAY=0 \
    "$APP/Contents/MacOS/ShareBar" "${args[@]}" >"$RUN/app-$label-$mode.log" 2>&1 &
  APP_PID=$!
  local i
  for i in $(seq 1 60); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  [[ -s $png ]] || { echo "parity-shots.sh: no image for $label $mode (see $RUN/app-$label-$mode.log)" >&2; exit 1; }
  echo "wrote $png"
}

for mode in light dark; do
  shoot calm "$mode"
  shoot menu "$mode" a1b2c3
done
