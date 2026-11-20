#!/bin/bash
# states-shots.sh: the popover screens of SPEC-009 TASK-4b21 to TASK-4b23, rendered through the app's
# DEBUG hook with no pointer or key input on the desktop (DEC-83). Each scene is
# `-ShareBarShotsRender <png> -ShareBarShotsScene <name>`; light and dark; the fake CLI answers from a
# scenario copy.
#
# Usage: mac/Tests/fixtures/states/states-shots.sh <out dir> [scene ...]
# Scenes: loading cli-missing cli-old first-run focus-third menu-shift-f10 publish-failure working-line
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/../../.." && pwd)"
FIX="$MAC/Tests/fixtures"
OUT="${1:?usage: states-shots.sh <out dir> [scene ...]}"
shift || true
SCENES=("$@")
if [[ ${#SCENES[@]} -eq 0 ]]; then SCENES=(loading cli-missing cli-old first-run focus-third menu-shift-f10 publish-failure working-line); fi
WORK="$MAC/build/states-shots"
mkdir -p "$OUT" "$WORK/gone"

APP_PID=""
cleanup() {
  if [[ -n $APP_PID ]]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

swift build --package-path "$MAC" >/dev/null
BIN="$(swift build --package-path "$MAC" --show-bin-path)"
APP="$WORK/Share Bar.app"
mkdir -p "$APP/Contents/MacOS"
command cp -f "$BIN/ShareBar" "$APP/Contents/MacOS/ShareBar"
command cp -f "$MAC/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier so.console.handout-bar.shots.states" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

prepare() { # prepare <scenario dir> [template]
  RUN="$WORK/run"
  mv "$RUN" "$WORK/gone/run.$$.$RANDOM" 2>/dev/null || true
  mkdir -p "$RUN/scenario"
  command cp -f "$1/member-ls.json" "$RUN/scenario/"
  if [[ -f $1/profiles.json.tmpl ]]; then
    sed -e "s/@D1@/$(date -v-1d +%F)/" -e "s/@D3@/$(date -v-3d +%F)/" -e "s/@D8@/$(date -v-8d +%F)/" \
        -e "s/@EXP27@/$(( $(date +%s) + 27 * 86400 + 3600 ))/" "$1/profiles.json.tmpl" > "$RUN/scenario/profiles.json"
  else
    command cp -f "$1/profiles.json" "$RUN/scenario/"
  fi
  : > "$RUN/argv.log"
}

shoot() { # shoot <scene> <light|dark>
  local scene="$1" mode="$2" png="$OUT/$1-$2.png" args=()
  mv -f "$png" "$WORK/gone/$(basename "$png").$$" 2>/dev/null || true
  args=(-ShareBarShotsRender "$png" -ShareBarShotsScene "$scene")
  [[ $mode == dark ]] && args+=(-ShareBarShotsAppearance dark)
  SHARE_BIN="$FIX/bin/share" SHARE_FAKE_DIR="$RUN" SHARE_FAKE_DELAY=0 \
    "$APP/Contents/MacOS/ShareBar" "${args[@]}" >"$RUN/app-$scene-$mode.log" 2>&1 &
  APP_PID=$!
  local i
  for i in $(seq 1 80); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  [[ -s $png ]] || { echo "states-shots.sh: no image for $scene $mode (see $RUN/app-$scene-$mode.log)" >&2; exit 1; }
  echo "wrote $png"
}

for scene in "${SCENES[@]}"; do
  case $scene in
    first-run) prepare "$FIX/scenarios/firstrun" ;;
    working-line) prepare "$HERE/scenarios/working" ;;
    *) prepare "$FIX/popover/scenarios/parity-calm" ;;
  esac
  for mode in light dark; do shoot "$scene" "$mode"; done
done
