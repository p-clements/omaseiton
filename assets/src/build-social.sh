#!/bin/bash
# Rebuilds assets/social-preview.png (1280 x 640, the size GitHub asks for in
# Settings > Social preview) from the emblem, the real dropdown screenshot
# (docs/panel.png) and the typography in social.svg.
#
# rsvg-convert will not follow ../ paths out of the SVG's folder, so the
# images are copied next to a copy of the SVG in a temp folder first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The emblem has its own dark background; flood it from the corners so the
# seal sits directly on the gradient.
magick ../emblem.png -alpha set -fuzz 9% -fill none \
  -draw "color 0,0 floodfill" -draw "color 511,0 floodfill" \
  -draw "color 0,511 floodfill" -draw "color 511,511 floodfill" "$tmp/emblem.png"
cp ../../docs/panel.png "$tmp/panel.png"
sed -e 's|href="../emblem.png"|href="emblem.png"|' -e 's|href="../../docs/panel.png"|href="panel.png"|' social.svg >"$tmp/social.svg"

rsvg-convert -w 1280 -h 640 "$tmp/social.svg" -o ../social-preview.png
echo "wrote assets/social-preview.png"
