#!/usr/bin/env bash
# Regenerate public/og.png from scripts/og-image.html.
#
# Headless Chrome's viewport under --window-size=1200,630 paints short of
# 630px, so we render into a 1200x900 window and top-left crop with PIL.
set -euo pipefail

cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TEMPLATE="$(pwd)/scripts/og-image.html"
RAW="/tmp/koji-og-raw.png"
OUT="$(pwd)/public/og.png"

if [ ! -x "$CHROME" ]; then
  echo "error: Google Chrome not found at $CHROME" >&2
  exit 1
fi

"$CHROME" \
  --headless=new \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --virtual-time-budget=8000 \
  --window-size=1200,900 \
  --screenshot="$RAW" \
  "file://$TEMPLATE"

python3 - <<PY
from PIL import Image
img = Image.open("$RAW")
img.crop((0, 0, 1200, 630)).save("$OUT")
PY

rm -f "$RAW"
echo "wrote $OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr '\n' ' '))"
