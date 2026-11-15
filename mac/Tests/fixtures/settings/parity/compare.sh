#!/bin/bash
# compare.sh <captures dir> <reference dir> <out dir>: for every capture that has a reference render,
# writes the side-by-side sheet to <out>/<label>-<appearance>.png and appends sRGB samples to
# <out>/samples.tsv: surface, primary ink, header title ink, header rule. Needs ./sample (swiftc -O sample.swift -o sample).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CAP="$1"; REF="$2"; OUT="$3"
SAMPLE="${SAMPLE_BIN:-$HERE/sample}"
mkdir -p "$OUT"
: > "$OUT/samples.tsv"
printf 'screen\tappearance\tmetric\treference\tcapture\tdelta\n' >> "$OUT/samples.tsv"
delta() { # delta #rrggbb #rrggbb -> max channel difference
  local a=${1#\#} b=${2#\#} i m=0 d
  for i in 0 2 4; do
    d=$(( 0x${a:$i:2} - 0x${b:$i:2} )); [[ $d -ge 0 ]] || d=$(( -d )); [[ $d -le $m ]] || m=$d
  done
  echo "$m"
}
for ref in "$REF"/*-light.png "$REF"/*-dark.png; do
  [[ -e $ref ]] || continue
  base="$(basename "$ref" .png)"; appearance="${base##*-}"; label="${base%-*}"
  cap="$CAP/4b-$label-$appearance.png"
  [[ -s $cap ]] || continue
  refh="$("$SAMPLE" content "$ref" "#ff00ff")"
  "$SAMPLE" side "$ref" "$cap" "$OUT/$label-$appearance.png" "$label ($appearance)" "$refh"
  caph="$(sips -g pixelHeight "$cap" | awk '/pixelHeight/ {print $2}')"
  # surface: the top-right corner of the header, empty in both (a sheet's scrim shows in both)
  rs="$("$SAMPLE" region "$ref" 1100 70 40 10 | sed 's/mode=\([^ ]*\).*/\1/')"
  cs="$("$SAMPLE" region "$cap" 1100 70 40 10 | sed 's/mode=\([^ ]*\).*/\1/')"
  # ink: the extreme pixel of the whole window (darkest in light, lightest in dark)
  if [[ $appearance == light ]]; then key=darkest; else key=lightest; fi
  ri="$("$SAMPLE" region "$ref" 100 80 1000 $((refh - 80)) | tr ' ' '\n' | sed -n "s/^$key=//p")"
  ci="$("$SAMPLE" region "$cap" 100 80 1000 $((caph - 80)) | tr ' ' '\n' | sed -n "s/^$key=//p")"
  # header title: the window title ink (secondary), x 480..760 near the top
  rt="$("$SAMPLE" region "$ref" 480 4 280 62 | tr ' ' '\n' | sed -n "s/^$key=//p")"
  ct="$("$SAMPLE" region "$cap" 480 4 280 62 | tr ' ' '\n' | sed -n "s/^$key=//p")"
  # header rule
  rr="$("$SAMPLE" rule "$ref" 30 100 300 | cut -d@ -f1)"
  cr="$("$SAMPLE" rule "$cap" 30 150 330 | cut -d@ -f1)"
  for row in "surface|$rs|$cs" "primary ink|$ri|$ci" "title ink|$rt|$ct" "header rule|$rr|$cr"; do
    IFS='|' read -r m a b <<<"$row"
    d="n/a"; [[ $a == \#* && $b == \#* ]] && d="$(delta "$a" "$b")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$appearance" "$m" "$a" "$b" "$d" >> "$OUT/samples.tsv"
  done
done
