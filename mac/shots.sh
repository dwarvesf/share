#!/bin/bash
# shots.sh: reach a Share Bar state through real clicks and key presses, then capture it.
#
# Usage: mac/shots.sh <scenario> <step file|name>     e.g. mac/shots.sh calm open-popover
#        mac/shots.sh all                             every step file, each with its own scenario
#
# It builds the app, starts it against the fake CLI (mac/Tests/fixtures/bin/share) with one
# scenario (mac/Tests/fixtures/scenarios/<scenario>), and replays the step file through the
# Accessibility API (mac/Tests/fixtures/ax/axdrive.swift): a real mouse click at the centre
# of a control found in the app's own tree, a real key press. Nothing sets state inside the
# app (SPEC-009 DEC-56). Each step file runs twice, light then dark; the dark run starts the
# app with `-AppleInterfaceStyle Dark`, so the machine's appearance never changes.
#
# Step file (mac/Tests/fixtures/steps/<name>.steps), one step per line, `#` starts a comment:
#   scenario <name>            default scenario for `shots.sh all`
#   click <control>            real click; <control> is `status-item` or a title/description
#   find <control>             fail unless the control exists
#   key <name> [cmd|opt|ctrl|shift]...
#   wait <seconds>
#   shot <label>               capture the frontmost Share Bar window
#   expect-argv <text>         fail unless a CLI call logged in argv.log contains <text>
#
# Images go to docs/verification/share-bar/<task>-<label>-<light|dark>.png (SHOTS_TASK,
# default 4b4; SHOTS_OUT overrides the directory). They are written to a temp directory
# and moved only after every step of both runs passed: a failing step leaves no image.
# A missing control fails the run with its name.
#
# Needs: Accessibility granted to the parent terminal, a logged-in unlocked desktop, jq.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$MAC_DIR/Tests/fixtures"
OUT_DIR="${SHOTS_OUT:-$MAC_DIR/../docs/verification/share-bar}"
TASK="${SHOTS_TASK:-4b4}"
WORK_ROOT="$MAC_DIR/build/shots"

die() { echo "shots.sh: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: mac/shots.sh <scenario> <step file|name> | all"

# Globals, so the EXIT trap can read them after any function returns.
APP_PID=""
RUN_DIR=""
IMG_DIR=""
cleanup() {
  if [[ -n $APP_PID ]]; then
    pkill -P "$APP_PID" 2>/dev/null || true
    kill "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n $RUN_DIR && -d $RUN_DIR ]]; then mv "$RUN_DIR" "$RUN_DIR.gone.$$" 2>/dev/null || true; fi
  if [[ -n $IMG_DIR && -d $IMG_DIR ]]; then mv "$IMG_DIR" "$IMG_DIR.gone.$$" 2>/dev/null || true; fi
}
trap cleanup EXIT

build_app() {
  echo "== build (debug)"
  swift build --package-path "$MAC_DIR" >/dev/null
  local bin
  bin="$(swift build --package-path "$MAC_DIR" --show-bin-path)"
  [[ -x $bin/ShareBar ]] || die "build did not produce $bin/ShareBar"
  APP="$WORK_ROOT/Share Bar.app"
  mkdir -p "$APP/Contents/MacOS"
  cp "$bin/ShareBar" "$APP/Contents/MacOS/ShareBar"
  cp "$MAC_DIR/Info.plist" "$APP/Contents/Info.plist"
  # Its own bundle id: the app under test never shares defaults with an installed Share Bar.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.dwarves.sharebar.shots" "$APP/Contents/Info.plist"
  codesign --force --sign - "$APP" >/dev/null 2>&1
}

build_driver() {
  AX="$WORK_ROOT/axdrive"
  local src="$FIXTURES/ax/axdrive.swift"
  if [[ ! -x $AX || $src -nt $AX ]]; then
    echo "== build axdrive"
    swiftc -O "$src" -o "$AX"
  fi
  "$AX" trusted >/dev/null 2>&1 || die "Accessibility is not granted to this terminal (System Settings > Privacy & Security > Accessibility)"
}

# step_error <n> <line> <message>
step_error() { echo "shots.sh: step $1 ($2): $3" >&2; exit 1; }

run_steps() { # run_steps <scenario> <steps file> <light|dark>
  local scenario="$1" steps="$2" appearance="$3" n=0 line cmd rest out
  local scenario_dir="$FIXTURES/scenarios/$scenario"
  [[ -d $scenario_dir ]] || die "no scenario: $scenario (look in mac/Tests/fixtures/scenarios)"

  RUN_DIR="$(mktemp -d "$WORK_ROOT/run.XXXXXX")"
  mkdir -p "$RUN_DIR/scenario"
  cp "$scenario_dir"/* "$RUN_DIR/scenario/"
  : > "$RUN_DIR/argv.log"

  local style_args=()
  [[ $appearance == dark ]] && style_args=(-AppleInterfaceStyle Dark)
  SHARE_BIN="$FIXTURES/bin/share" SHARE_FAKE_DIR="$RUN_DIR" SHARE_FAKE_DELAY=0.4 \
    "$APP/Contents/MacOS/ShareBar" ${style_args[@]+"${style_args[@]}"} >"$RUN_DIR/app.log" 2>&1 &
  APP_PID=$!

  # The app is up once its status item is in the Accessibility tree.
  "$AX" find "$APP_PID" status-item 15 >/dev/null 2>&1 || step_error 0 "launch" "the app's status item never appeared (see $RUN_DIR/app.log)"
  sleep 1.5   # first profiles read

  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n $line ]] || continue
    n=$((n + 1))
    cmd="${line%% *}"
    rest=""
    [[ $line == *" "* ]] && rest="${line#* }"
    case $cmd in
      scenario) ;;
      click)
        [[ -n $rest ]] || step_error "$n" "$line" "click needs a control"
        out="$("$AX" click "$APP_PID" "$rest" 4 2>&1)" || step_error "$n" "$line" "$out"
        sleep 0.6 ;;
      find)
        out="$("$AX" find "$APP_PID" "$rest" 4 2>&1)" || step_error "$n" "$line" "$out" ;;
      key)
        # shellcheck disable=SC2086
        out="$("$AX" key $rest 2>&1)" || step_error "$n" "$line" "$out"
        sleep 0.4 ;;
      wait)
        sleep "$rest" ;;
      shot)
        [[ -n $rest ]] || step_error "$n" "$line" "shot needs a label"
        sleep 0.5
        local win
        win="$("$AX" window "$APP_PID" 2>&1)" || step_error "$n" "$line" "$win"
        mkdir -p "$IMG_DIR"
        screencapture -x -o -l "$win" "$IMG_DIR/$TASK-$rest-$appearance.png" || step_error "$n" "$line" "screencapture failed"
        [[ -s $IMG_DIR/$TASK-$rest-$appearance.png ]] || step_error "$n" "$line" "screencapture wrote nothing" ;;
      expect-argv)
        sleep 0.8
        grep -qF -- "$rest" "$RUN_DIR/argv.log" || step_error "$n" "$line" "no CLI call logged \"$rest\" (argv.log: $(tr '\n' ';' < "$RUN_DIR/argv.log"))" ;;
      *) step_error "$n" "$line" "unknown step" ;;
    esac
  done < "$steps"

  cp "$RUN_DIR/argv.log" "$IMG_DIR/argv-$appearance.log"
  pkill -P "$APP_PID" 2>/dev/null || true
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  mv "$RUN_DIR" "$RUN_DIR.done" 2>/dev/null || true
  RUN_DIR=""
}

resolve_steps() { # resolve_steps <name|path>
  if [[ -f $1 ]]; then echo "$1"; elif [[ -f $FIXTURES/steps/$1.steps ]]; then echo "$FIXTURES/steps/$1.steps"; else die "no step file: $1"; fi
}

run_one() { # run_one <scenario> <step name|path>
  local steps
  steps="$(resolve_steps "$2")"
  echo "== $1 / $(basename "$steps" .steps)"
  IMG_DIR="$(mktemp -d "$WORK_ROOT/img.XXXXXX")"
  run_steps "$1" "$steps" light
  run_steps "$1" "$steps" dark
  mkdir -p "$OUT_DIR"
  local f
  for f in "$IMG_DIR"/*.png; do
    [[ -e $f ]] || continue
    mv -f "$f" "$OUT_DIR/"
    echo "wrote ${OUT_DIR#"$MAC_DIR/../"}/$(basename "$f")"
  done
  echo "argv.log (light): $(tr '\n' ';' < "$IMG_DIR/argv-light.log")"
  mv "$IMG_DIR" "$IMG_DIR.done"
  IMG_DIR=""
}

mkdir -p "$WORK_ROOT"
build_app
build_driver

if [[ $1 == all ]]; then
  for steps in "$FIXTURES"/steps/*.steps; do
    scenario="$(sed -n 's/^scenario[[:space:]]*//p' "$steps" | head -1)"
    [[ -n $scenario ]] || die "$(basename "$steps") has no scenario line"
    run_one "$scenario" "$steps"
  done
else
  [[ $# -ge 2 ]] || die "usage: mac/shots.sh <scenario> <step file|name>"
  run_one "$1" "$2"
fi
