#!/bin/bash
# popover-b-parity.sh: design parity of the popover B screens (owner rule 2026-11-15). For each scene
# and appearance it renders the matching revision 8 screen of docs/design/share-bar-redesign.html in
# headless Chromium (Helium), crops it, puts it beside the build's capture, and samples both in sRGB.
#
# Usage: mac/Tests/fixtures/popover/popover-b-parity.sh <captures dir> <out dir> [scene ...]
#   <captures dir> holds <scene>-<light|dark>.png from popover-b-shots.sh.
# Needs: Helium (or CHROME=/path to a Chromium), python3, swiftc. No pointer or key input.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
CAP="${1:?usage: popover-b-parity.sh <captures dir> <out dir> [scene ...]}"
OUT="${2:?usage: popover-b-parity.sh <captures dir> <out dir> [scene ...]}"
shift 2 || true
SCENES=("$@")
if [[ ${#SCENES[@]} -eq 0 ]]; then SCENES=(drop uploading flashed dragout hotkey ql-pdf ql-folder ql-port ql-cloud); fi
CHROME="${CHROME:-/Applications/Helium.app/Contents/MacOS/Helium}"
WORK="${TMPDIR:-/tmp}/popover-b-parity.$$"
mkdir -p "$OUT" "$WORK"
swiftc -O "$HERE/popover-b-sample.swift" -o "$WORK/sample" 2>/dev/null

headless() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=1000,1100 --virtual-time-budget=3500 "$@" 2>/dev/null; }

probes() { # probes <scene> -> one probe per line, in 2x crop pixels
  case $1 in
    drop)
      echo "bg:surface:8,260"; echo "bg:overlay background:100,120"
      echo "ink:headline (primary):150,262,530,298"; echo "ink:detail (secondary):90,305,590,328" ;;
    uploading|flashed|dragout|hotkey)
      echo "bg:background:8,300"; echo "ink:primary text:30,28,160,58"; echo "ink:secondary text:108,204,180,224"
      [[ $1 == hotkey ]] || echo "ink:search placeholder:78,96,222,120:16"
      echo "line:separator:340,-100,-50"
      [[ $1 == flashed || $1 == dragout ]] && echo "ink:footer text:60,-50,500,-24" || true ;;
    ql-*)
      echo "bg:header background:600,16"; echo "ink:title (primary):260,28,500,58"
      echo "ink:meta (secondary):28,-44,300,-20"; echo "ink:url (mono, primary):28,-82,560,-54"
      echo "line:header separator:40,70,100" ;;
  esac
}

fail=0
for scene in "${SCENES[@]}"; do
  for theme in light dark; do
    page="$WORK/$scene-$theme.html"; png="$WORK/design-$scene-$theme.png"
    python3 "$HERE/design-scene.py" "$REPO/docs/design/share-bar-redesign.html" "$page" "$scene" "$theme"
    headless --screenshot="$png" "file://$page" >/dev/null
    w=680; [[ $scene == ql-* ]] && w=1120
    args=()
    while IFS= read -r line; do [[ -n $line ]] && args+=("$line"); done < <(probes "$scene")
    echo "== $scene $theme"
    if "$WORK/sample" "$png" -1 -1 "$w" 0 "$CAP/$scene-$theme.png" "$OUT/$scene-$theme-parity.png" "$theme" "${args[@]}" | tee -a "$OUT/samples.txt"; then :; else fail=1; fi
  done
done
exit $fail
