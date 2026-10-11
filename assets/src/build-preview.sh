#!/bin/bash
# Rebuilds preview.png (the marketplace listing image) from the emblem, the
# real dropdown screenshot (docs/panel.png) and the typography in preview.svg.
#
# rsvg-convert will not follow ../ paths out of the SVG's folder, so the
# images are copied next to a copy of the SVG in a temp folder first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The emblem has its own dark background; flood it from the corners so the
# seal sits directly on the preview gradient.
magick ../emblem.png -alpha set -fuzz 9% -fill none \
  -draw "color 0,0 floodfill" -draw "color 511,0 floodfill" \
  -draw "color 0,511 floodfill" -draw "color 511,511 floodfill" "$tmp/emblem.png"
cp ../../docs/panel.png "$tmp/panel.png"
sed -e 's|href="../emblem.png"|href="emblem.png"|' -e 's|href="../../docs/panel.png"|href="panel.png"|' preview.svg >"$tmp/preview.svg"

rsvg-convert -w 1280 -h 720 "$tmp/preview.svg" -o ../../preview.png
echo "wrote preview.png"
