#!/usr/bin/env bash
# Regenerate the favicon PNG set from scripts/favicon-source.html.
#
# Renders once at 512x512 via headless Chrome, then downscales to 180 and 32
# with high-quality PIL resampling. Chrome won't render viewports below ~500px,
# so single-render-plus-downscale is both simpler and sharper than multi-render.
#
# Outputs:
#   public/favicon-32.png         — standard desktop favicon
#   public/apple-touch-icon.png   — 180x180, iOS home screen
#   public/favicon-512.png        — PWA manifest / high-res
#   public/favicon.ico            — 16+32 ICO fallback for legacy browsers
set -euo pipefail

cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SRC="$(pwd)/scripts/favicon-source.html"
RAW="/tmp/koji-favicon-raw.png"

"$CHROME" \
  --headless=new \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --window-size=512,512 \
  --screenshot="$RAW" \
  "file://$SRC" 2>&1 | tail -1

python3 - <<'PY'
from PIL import Image

src = Image.open("/tmp/koji-favicon-raw.png").crop((0, 0, 512, 512))
src.save("public/favicon-512.png")

for size, name in [(180, "public/apple-touch-icon.png"), (32, "public/favicon-32.png")]:
    src.resize((size, size), Image.LANCZOS).save(name)

src.save("public/favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)])
print("wrote 512, 180, 32 PNGs + ICO")
PY

rm -f "$RAW"
ls -la public/favicon* public/apple-touch-icon.png
