#!/bin/bash
# render-reference.sh <out dir> [label]...: renders revision 8 of docs/design/share-bar-redesign.html
# headless, once per screen of screens.tsv and appearance, as <label>-<light|dark>.png at 2x. The
# page is a copy of the design with one script appended (scenario, appearance, then the lines of
# screens.tsv); only the window is shown, on a magenta ground so the content height can be read.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
DESIGN="$REPO/docs/design/share-bar-redesign.html"
BROWSER="${PARITY_BROWSER:-/Applications/Brave Browser.app/Contents/MacOS/Brave Browser}"
OUT="$1"; shift
mkdir -p "$OUT/html"
want=" $* "
while IFS=$'\t' read -r label scenario js; do
  [[ -n $label ]] || continue
  [[ $# -eq 0 || $want == *" $label "* ]] || continue
  for appearance in light dark; do
    page="$OUT/html/$label-$appearance.html"
    python3 -I - "$DESIGN" "$page" "$scenario" "$appearance" "$js" <<'PY'
import sys
design, page, scenario, appearance, js = sys.argv[1:6]
s = open(design, encoding="utf-8").read()
css = "<style>html,body{margin:0!important;padding:0!important;background:#ff00ff!important}body *{visibility:hidden}#win,#win *{visibility:visible}#win{position:fixed!important;left:0;top:0;margin:0!important;width:620px}.toast{display:none}</style>"
i0 = s.index("<header>")
s = s[:i0] + css + s[i0:]
call = "(function(){document.getElementById('a-%s').click();document.getElementById('s-%s').click();%s})();" % (appearance, scenario, js)
i = s.rindex("</script>")
s = s[:i] + call + "\n" + s[i:]
open(page, "w", encoding="utf-8").write(s)
PY
    "$BROWSER" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=620,1200 \
      --virtual-time-budget=3000 --screenshot="$OUT/$label-$appearance.png" "file://$page" >/dev/null 2>&1 || true
    [[ -s $OUT/$label-$appearance.png ]] || { echo "render-reference.sh: no render for $label $appearance" >&2; exit 1; }
  done
done < "$HERE/screens.tsv"
