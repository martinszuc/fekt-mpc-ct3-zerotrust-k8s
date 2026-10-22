#!/usr/bin/env bash
# renders docs/figures/*.svg to vector PDF (report) and 2x PNG (slides) with headless Chrome
# the SVGs pull their fonts from Google Fonts, so this needs network access
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for svg in docs/figures/*.svg; do
  base=${svg%.svg}
  read -r w h < <(sed -n 's/.*viewBox="0 0 \([0-9]*\) \([0-9]*\)".*/\1 \2/p' "$svg" | head -1)
  page=$tmp/$(basename "$base").html
  # inline, not <img>: SVG images cannot load the font @import
  { printf '<!doctype html><meta charset="utf-8"><style>@page{size:%spx %spx;margin:0}html,body{margin:0}svg{display:block;width:%spx;height:%spx}</style>' "$w" "$h" "$w" "$h"
    sed '1{/^<?xml/d;}' "$svg"
  } > "$page"
  "$CHROME" --headless --disable-gpu --no-pdf-header-footer --virtual-time-budget=5000 \
    --print-to-pdf="$base.pdf" "file://$page" 2>/dev/null
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --virtual-time-budget=5000 \
    --window-size="$w,$h" --screenshot="$base.png" "file://$page" 2>/dev/null
  echo "$base.pdf $base.png"
done
