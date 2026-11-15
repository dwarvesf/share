#!/bin/bash
# status-item-check.sh: TASK-4b8 "status item with its dot". The status item is not a window, and
# this desk has no live display (a whole-display capture reads black and the item's window is not
# listed), so no image of the menu bar can be taken here. The check is the one that does not need
# pixels: launch the same debug app against a scenario and require the status item's Accessibility
# label to carry the count, with no click and no state set by the script. The dot itself is the
# subview `applyAttention` adds when that count is above zero.
#
# Usage: status-item-check.sh <scenario> <expected label>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$HERE/../../.." && pwd)"
WORK="$MAC/build/shots"
APP_BIN="$WORK/Share Bar.app/Contents/MacOS/ShareBar"
AX="$WORK/axdrive"
[[ -x $APP_BIN && -x $AX ]] || { echo "status-item-check.sh: run mac/shots.sh once first (it builds the app and axdrive)" >&2; exit 1; }

scenario="$1" label="$2"
src="$HERE/scenarios/$scenario"
[[ -d $src ]] || src="$HERE/../scenarios/$scenario"
[[ -d $src ]] || { echo "status-item-check.sh: no scenario $scenario" >&2; exit 1; }

APP_PID=""
RUN=""
cleanup() {
  if [[ -n $APP_PID ]]; then pkill -P "$APP_PID" 2>/dev/null || true; kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  if [[ -n $RUN && -d $RUN ]]; then mv "$RUN" "$RUN.gone.$$" 2>/dev/null || true; fi
}
trap cleanup EXIT

RUN="$(mktemp -d "$WORK/run.XXXXXX")"
mkdir -p "$RUN/scenario"
cp "$src"/* "$RUN/scenario/"
: > "$RUN/argv.log"
SHARE_BIN="$MAC/Tests/fixtures/bin/share" SHARE_FAKE_DIR="$RUN" "$APP_BIN" >"$RUN/app.log" 2>&1 &
APP_PID=$!

# A collapsed menu bar manager hides third-party items; expand it once, as shots.sh does.
if ! "$AX" find "$APP_PID" status-item 3 >/dev/null 2>&1; then
  hb="$(pgrep -x "Hidden Bar" | head -1 || true)"
  [[ -n $hb ]] && "$AX" click "$hb" status-item 2 >/dev/null 2>&1 && sleep 1
fi
"$AX" find "$APP_PID" status-item 6 >/dev/null 2>&1 || { echo "status-item-check.sh: the status item never appeared" >&2; exit 1; }
"$AX" find "$APP_PID" "$label" 8 >/dev/null 2>&1 || { echo "status-item-check.sh: the status item never read \"$label\"" >&2; exit 1; }
echo "status item of $scenario reads \"$label\""
