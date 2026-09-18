#!/bin/bash
# render.sh <story>: record demo/<story>.tape with vhs, then assemble demo/<story>.gif.
# vhs captures the terminal frames; ffmpeg builds the GIF here because vhs's own
# encoder step fails silently with ffmpeg 9 (it prints "Creating" and writes nothing).
set -euo pipefail
cd "$(dirname "$0")/.."
story="${1:?usage: demo/render.sh setup|use}"
frames="demo/.frames/$story"
rm -rf "$frames"
mkdir -p demo/.frames   # vhs creates only the last level of an Output directory
vhs "demo/$story.tape"
ffmpeg -hide_banner -loglevel error -y \
  -framerate 50 -i "$frames/frame-text-%05d.png" \
  -framerate 50 -i "$frames/frame-cursor-%05d.png" \
  -filter_complex "[0][1]overlay,pad=iw+48:ih+48:24:24:color=0x282c34,fps=20,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "demo/$story.gif"
echo "wrote demo/$story.gif ($(du -h "demo/$story.gif" | cut -f1))"
