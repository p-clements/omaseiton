#!/bin/bash
# Rebuilds assets/banner.png from the generated artwork (banner-art.png) and
# the typography in banner.svg. Needs ImageMagick (magick) and rsvg-convert,
# plus the fonts named in banner.svg (Noto Serif CJK JP, JetBrainsMono Nerd
# Font, Geist).
#
# The generated art is 1920x512 but its left 640px is flat padding, so the real
# art (the right 1280px) has its left edge faded into the page navy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

magick banner-art.png -crop 1280x512+640+0 +repage "$tmp/art-crop.png"
magick -size 512x460 gradient:black-white -rotate -90 "$tmp/fade.png"
magick -size 820x512 xc:white "$tmp/solid.png"
magick "$tmp/fade.png" "$tmp/solid.png" +append "$tmp/mask.png"
magick "$tmp/art-crop.png" "$tmp/mask.png" -alpha off -compose copy_opacity -composite "$tmp/art-faded.png"
magick -size 1920x512 xc:'#0f1226' "$tmp/art-faded.png" -geometry +640+0 -composite banner-bg.png

rsvg-convert -w 1920 -h 512 banner.svg -o ../banner.png
echo "wrote assets/banner.png"
