#!/bin/bash
# run-shots.sh: the popover's screenshot run. It replays each step file of this folder through
# mac/shots.sh (real clicks and key events through the Accessibility API) and adds the two
# things shots.sh does not do:
#
#   # on-argv: <argv> => <jq filter>   the CLI answers differently once that call is logged: the
#                                      filter edits the scenario's profiles.json, as the real CLI's
#                                      state would change after a journal's Resume completes.
#   # expect-rm: <n>                   `rm <id>` appears exactly n times in argv.log, light and dark.
#
# Usage: mac/Tests/fixtures/popover/run-shots.sh [step name]...   (default: every step file here)
# Images land in docs/verification/share-bar/popover-a/ (4b-<label>-<light|dark>.png).
# Needs what shots.sh needs: Accessibility on the terminal, an unlocked desktop, jq.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/../../.." && pwd)"
export SHOTS_OUT="${SHOTS_OUT:-$MAC/../docs/verification/share-bar/popover-a}"
export SHOTS_TASK="${SHOTS_TASK:-4b}"
WORK="$MAC/build/shots"

WATCH_PID=""
stop_watcher() {
  if [[ -n $WATCH_PID ]]; then kill "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; WATCH_PID=""; fi
}
trap stop_watcher EXIT

# watch <argv> <jq filter>: every run directory shots.sh makes gets the edit once, after the call is logged.
watch_loop() {
  local pattern="$1" filter="$2" dir marker
  while :; do
    for dir in "$WORK"/run.??????; do
      [[ -d $dir/scenario ]] || continue
      marker="$dir/.applied"
      [[ ! -e $marker ]] || continue
      if sed 's/^--profile [^ ]* //' "$dir/argv.log" 2>/dev/null | grep -qxF -- "$pattern"; then
        jq -c "$filter" "$dir/scenario/profiles.json" > "$dir/scenario/profiles.json.tmp" && mv -f "$dir/scenario/profiles.json.tmp" "$dir/scenario/profiles.json"
        : > "$marker"
      fi
    done
    sleep 0.2
  done
}

count_rm() { sed 's/^--profile [^ ]* //' "$1" | grep -c '^rm ' || true; }

run_one() {
  local name="$1" file scenario onargv="" pattern filter expect=""
  file="$HERE/steps/$name.steps"
  [[ -f $file ]] || { echo "run-shots.sh: no step file $name" >&2; exit 1; }
  scenario="$(sed -n 's/^scenario[[:space:]]*//p' "$file" | head -1)"
  onargv="$(sed -n 's/^# on-argv:[[:space:]]*//p' "$file" | head -1)"
  expect="$(sed -n 's/^# expect-rm:[[:space:]]*//p' "$file" | head -1)"
  if [[ -n $onargv ]]; then
    pattern="${onargv%% => *}"
    filter="${onargv#* => }"
    watch_loop "$pattern" "$filter" &
    WATCH_PID=$!
  fi
  bash "$MAC/shots.sh" "$scenario" "$file"
  stop_watcher
  if [[ -n $expect ]]; then
    local done_dir light dark
    done_dir="$(ls -dt "$WORK"/img.*.done 2>/dev/null | head -1)"
    light="$(count_rm "$done_dir/argv-light.log")"
    dark="$(count_rm "$done_dir/argv-dark.log")"
    if [[ $light != "$expect" || $dark != "$expect" ]]; then
      echo "run-shots.sh: $name expected $expect rm call(s), saw light=$light dark=$dark" >&2
      exit 1
    fi
    echo "== $name: rm calls light=$light dark=$dark (expected $expect)"
  fi
}

if [[ $# -gt 0 ]]; then
  for n in "$@"; do run_one "$n"; done
else
  for f in "$HERE"/steps/*.steps; do run_one "$(basename "$f" .steps)"; done
  bash "$HERE/status-item-check.sh" needs-four "Handout Bar, 4 need a look"
  bash "$HERE/status-item-check.sh" ../../scenarios/calm "Handout Bar"
fi
