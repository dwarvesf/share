#!/bin/bash
# run-shots.sh: the Settings screens' screenshot run (SPEC-009 TASK-4b14 to 4b18).
#
# Owner decision 2026-11-15: no pointer, key or drag input on the live desktop. Each step file
# launches the built debug app against the fake CLI (this folder's bin/share) with
# `-ShareBarShotsScreen "<script>"`; the app runs that script through its own store methods
# (Settings/ShotsHooks.swift), writes $SHARE_FAKE_DIR/shots-ready, and this script captures the
# window with `screencapture -l` and kills the app. Light then dark (dark through
# `-ShareBarShotsAppearance dark`; the machine's appearance never changes).
#
# Step file (steps/<name>.shot), one line each, `#` starts a comment:
#   scenario <name>             a folder of this directory's scenarios/
#   script <steps>             the comma-separated hook script (see ShotsHooks.swift)
#   hold <n>                   SHARE_FAKE_HOLD_AT: the journaled verb waits after step n
#   delay <seconds>            SHARE_FAKE_DELAY
#   expect-argv <args>         a whole call in argv.log, `--profile <name>` ignored
#   expect-no-argv <prefix>    no call starting with this (after `--profile` is ignored)
#   expect-env <VAR>=<present|absent>   the last env.log line for VAR
#   label <name>               the image name: 4b-<label>-<light|dark>.png
#
# Usage: mac/Tests/fixtures/settings/run-shots.sh [step name]...   (default: every step file)
# Images land in docs/verification/share-bar/settings-a/. Needs jq and Screen Recording for the
# terminal; an unlocked desktop is not needed for input, only for the capture.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/../../.." && pwd)"
OUT_DIR="${SHOTS_OUT:-$MAC/../docs/verification/share-bar/settings-a}"
WORK="$MAC/build/settings-shots"
BUNDLE_ID="com.dwarves.sharebar.shots.settings"
APP="$WORK/Share Bar.app"

APP_PID=""
RUN_DIR=""
cleanup() {
  if [[ -n $APP_PID ]]; then
    pkill -P "$APP_PID" 2>/dev/null || true
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

die() { echo "run-shots.sh: $*" >&2; exit 1; }

build_app() {
  echo "== build (debug)"
  swift build --package-path "$MAC" >/dev/null
  local bin
  bin="$(swift build --package-path "$MAC" --show-bin-path)"
  [[ -x $bin/ShareBar ]] || die "build did not produce $bin/ShareBar"
  mkdir -p "$APP/Contents/MacOS"
  command cp -f "$bin/ShareBar" "$APP/Contents/MacOS/ShareBar"
  command cp -f "$MAC/Info.plist" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
  codesign --force --sign - "$APP" >/dev/null 2>&1
}

field() { sed -n "s/^$1[[:space:]]*//p" "$2" | head -1; }
fields() { sed -n "s/^$1[[:space:]]*//p" "$2"; }

capture() { # capture <step file> <light|dark>
  local file="$1" appearance="$2" name scenario script hold delay label
  name="$(basename "$file" .shot)"
  scenario="$(field scenario "$file")"
  script="$(field script "$file")"
  hold="$(field hold "$file")"
  delay="$(field delay "$file")"
  label="$(field label "$file")"
  [[ -d $HERE/scenarios/$scenario ]] || die "$name: no scenario $scenario"
  [[ -n $script && -n $label ]] || die "$name: needs a script and a label"

  RUN_DIR="$(mktemp -d "$WORK/run.XXXXXX")"
  mkdir -p "$RUN_DIR/scenario"
  command cp -f "$HERE/scenarios/$scenario"/* "$RUN_DIR/scenario/"
  # a code that expires in 6 days, read against the clock of the run
  [[ ! -f $RUN_DIR/scenario/member-ls.json ]] || sed -i '' "s/@EXP6@/$(( $(date +%s) + 6 * 86400 + 3600 ))/g" "$RUN_DIR/scenario/member-ls.json"
  : > "$RUN_DIR/argv.log"
  : > "$RUN_DIR/env.log"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

  local style=()
  [[ $appearance == dark ]] && style=(-ShareBarShotsAppearance dark)
  env -u XDG_CONFIG_HOME SHARE_BIN="$HERE/bin/share" SHARE_FAKE_DIR="$RUN_DIR" SHAREBAR_OP_BIN="$HERE/bin/op" \
    SHARE_FAKE_DELAY="${delay:-0.4}" ${hold:+SHARE_FAKE_HOLD_AT=$hold} \
    "$APP/Contents/MacOS/ShareBar" ${style[@]+"${style[@]}"} -ShareBarShotsScreen "$script" >"$RUN_DIR/app.log" 2>&1 &
  APP_PID=$!

  local waited=0
  while [[ ! -s $RUN_DIR/shots-ready ]]; do
    sleep 0.3
    waited=$((waited + 1))
    kill -0 "$APP_PID" 2>/dev/null || die "$name ($appearance): the app exited (see $RUN_DIR/app.log)"
    [[ $waited -lt 200 ]] || die "$name ($appearance): the script never finished (see $RUN_DIR/app.log)"
  done
  local win
  win="$(head -1 "$RUN_DIR/shots-ready" | tr -d ' ')"
  [[ $win =~ ^[1-9][0-9]*$ ]] || die "$name: the app reported no window ($win)"
  sleep 0.5
  mkdir -p "$IMG_DIR"
  local image="$IMG_DIR/4b-$label-$appearance.png"
  screencapture -x -o -l "$win" "$image" || die "$name: screencapture failed"
  [[ -s $image ]] || die "$name: screencapture wrote nothing"

  # the checks read the logs once the shot is taken, so a slow verb is not cut short
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    sed 's/^--profile [^ ]* //' "$RUN_DIR/argv.log" | grep -qxF -- "$line" \
      || die "$name ($appearance): no CLI call logged \"$line\" (argv.log: $(tr '\n' ';' < "$RUN_DIR/argv.log"))"
  done < <(fields expect-argv "$file")
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if sed 's/^--profile [^ ]* //' "$RUN_DIR/argv.log" | grep -q -- "^$line"; then
      die "$name ($appearance): a call starting \"$line\" was logged, expected none"
    fi
  done < <(fields expect-no-argv "$file")
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    local var="${line%%=*}" want="${line#*=}" got
    got="$(grep "^$var=" "$RUN_DIR/env.log" | tail -1 | cut -d= -f2)"
    [[ $got == "$want" ]] || die "$name ($appearance): $var was \"$got\", expected \"$want\""
  done < <(fields expect-env "$file")
  command cp -f "$RUN_DIR/argv.log" "$IMG_DIR/argv-$name-$appearance.log"

  pkill -P "$APP_PID" 2>/dev/null || true
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  mv "$RUN_DIR" "$RUN_DIR.done"
  RUN_DIR=""
}

mkdir -p "$WORK" "$OUT_DIR"
build_app

if [[ $# -gt 0 ]]; then
  files=()
  for n in "$@"; do files+=("$HERE/steps/$n.shot"); done
else
  files=("$HERE"/steps/*.shot)
fi

for file in "${files[@]}"; do
  [[ -f $file ]] || die "no step file $file"
  IMG_DIR="$(mktemp -d "$WORK/img.XXXXXX")"
  echo "== $(basename "$file" .shot)"
  capture "$file" light
  capture "$file" dark
  for f in "$IMG_DIR"/*.png; do
    [[ -e $f ]] || continue
    mv -f "$f" "$OUT_DIR/"
    echo "wrote ${OUT_DIR#"$MAC/../"}/$(basename "$f")"
  done
  mkdir -p "$OUT_DIR/argv"
  for f in "$IMG_DIR"/argv-*.log; do
    [[ -e $f ]] || continue
    mv -f "$f" "$OUT_DIR/argv/"
  done
  mv "$IMG_DIR" "$IMG_DIR.done"
done
