#!/bin/bash
# icons.sh: draw the Share Bar app icon from code. Compiles Tools/make-icons.swift
# together with ShareBarCore's Mark.swift (so the icon and the menu bar glyph share one
# set of shapes), runs it, and builds AppIcon.icns from the iconset with iconutil.
#
# Usage: mac/icons.sh <outdir>
# Writes <outdir>/{master-1024.png,contact-sheet.png,AppIcon.iconset/,AppIcon.icns};
# the last stdout line is the .icns path.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-}"
[[ -n "$OUT" ]] || { echo "usage: mac/icons.sh <outdir>" >&2; exit 2; }

mkdir -p "$OUT"
TOOL="$(mktemp -d)/make-icons"
swiftc -O -parse-as-library \
  "$MAC_DIR/Tools/make-icons.swift" "$MAC_DIR/Sources/ShareBarCore/Mark.swift" \
  -o "$TOOL"
"$TOOL" "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
echo "$OUT/AppIcon.icns"
