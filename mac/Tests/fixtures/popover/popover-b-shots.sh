#!/bin/bash
# popover-b-shots.sh: render the popover B screens through the app's DEBUG hook, with no pointer or
# key input on the desktop (SPEC-009 DEC-83). Every scene is `-ShareBarShotsScene <name>` on top of
# `-ShareBarShotsRender <png>`; light and dark; the fake CLI answers from a scenario copy.
#
# Usage: mac/Tests/fixtures/popover/popover-b-shots.sh <out dir> [scene ...]
# Scenes: drop uploading flashed dragout hotkey ql-pdf ql-folder ql-port ql-cloud publish-live (default: all)
# publish-live drives the real drop path against the fake CLI and prints the `add` call it left in argv.log.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/../../.." && pwd)"
OUT="${1:?usage: popover-b-shots.sh <out dir> [scene ...]}"
shift || true
SCENES=("$@")
if [[ ${#SCENES[@]} -eq 0 ]]; then SCENES=(drop uploading flashed dragout hotkey ql-pdf ql-folder ql-port ql-cloud); fi
WORK="$MAC/build/popover-b"
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
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier so.console.handout-bar.shots" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

prepare() { # prepare <scenario dir name>
  RUN="$WORK/run"
  mv "$RUN" "$WORK/gone/run.$$.$RANDOM" 2>/dev/null || true
  mkdir -p "$RUN/scenario" "$RUN/home/share/pub/pd0001" "$RUN/home/share/pub/d4e5f6/trang-mobility/scenes"
  command cp -f "$HERE/scenarios/$1/member-ls.json" "$RUN/scenario/"
  sed -e "s/@D1@/$(date -v-1d +%F)/" -e "s/@D3@/$(date -v-3d +%F)/" -e "s/@D8@/$(date -v-8d +%F)/" \
      -e "s/@EXP27@/$(( $(date +%s) + 27 * 86400 + 3600 ))/" \
      "$HERE/scenarios/$1/profiles.json.tmpl" > "$RUN/scenario/profiles.json"
  : > "$RUN/argv.log"
  command cp -f "$HERE/files/Q4-plan.pdf" "$RUN/home/share/pub/pd0001/Q4-plan.pdf"
  command cp -f "$HERE/files/Q4-plan.pdf" "$RUN/home/Q4-plan.pdf"
  for f in index.html readme.md demo-1.mp4 demo-2.mp4; do : > "$RUN/home/share/pub/d4e5f6/trang-mobility/$f"; done
}

shoot() { # shoot <scene> <light|dark>
  local scene="$1" mode="$2" png="$OUT/$1-$2.png" args=()
  mv -f "$png" "$WORK/gone/$(basename "$png").$$" 2>/dev/null || true
  args=(-ShareBarShotsRender "$png" -ShareBarShotsScene "$scene")
  [[ $mode == dark ]] && args+=(-ShareBarShotsAppearance dark)
  local delay=0; [[ $scene == publish-live ]] && delay=0.8
  SHARE_BIN="$MAC/Tests/fixtures/bin/share" SHARE_FAKE_DIR="$RUN" SHARE_FAKE_DELAY=$delay SHARE_SHOTS_HOME="$RUN/home" SHARE_SHOTS_DROP_FILE="$RUN/home/Q4-plan.pdf" \
    "$APP/Contents/MacOS/ShareBar" "${args[@]}" >"$RUN/app-$scene-$mode.log" 2>&1 &
  APP_PID=$!
  local i
  for i in $(seq 1 80); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  [[ -s $png ]] || { echo "popover-b-shots.sh: no image for $scene $mode (see $RUN/app-$scene-$mode.log)" >&2; exit 1; }
  echo "wrote $png"
  if [[ $scene == publish-live ]]; then grep -E "(^| )add " "$RUN/argv.log" | sed "s#$RUN/home#<home>#" | sed "s/^/argv.log: /"; fi
}

for scene in "${SCENES[@]}"; do
  case $scene in
    ql-*) prepare popover-b ;;
    *) prepare parity-calm ;;
  esac
  for mode in light dark; do shoot "$scene" "$mode"; done
done
