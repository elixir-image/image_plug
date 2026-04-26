#!/usr/bin/env bash
# Re-vendor curated test images from the Image library.
#
# Usage: from the project root, run:
#     test/fixtures/vendor_images.sh [path-to-image-library]
#
# Defaults to ../image (the sibling Image library checkout in the
# typical workspace layout).
set -euo pipefail

SRC="${1:-../image/test/support/images}"
DST="$(cd "$(dirname "$0")/images" && pwd)"

if [ ! -d "$SRC" ]; then
  echo "image library fixtures not found at $SRC" >&2
  exit 1
fi

cp "$SRC/Kip_small.jpg"             "$DST/portrait.jpg"
cp "$SRC/Kip_small.png"             "$DST/portrait.png"
cp "$SRC/Kip_small_rotated.jpg"     "$DST/portrait_rotated.jpg"
cp "$SRC/penguin_with_alpha.png"    "$DST/alpha.png"
cp "$SRC/2x2-maze.png"              "$DST/tiny.png"
cp "$SRC/Sydney-Opera-House-BW.jpg" "$DST/landscape.jpg"
cp "$SRC/puppy.webp"                "$DST/sample.webp"
cp "$SRC/animated.webp"             "$DST/animated.webp"
cp "$SRC/jose.png"                  "$DST/large.png"

echo "Vendored 9 fixtures into $DST" >&2
