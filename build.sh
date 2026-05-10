#!/usr/bin/env bash
# Build picsort.com from src/.
# Downloads redbean once, then bundles src/ into the binary as a zip.
set -euo pipefail
cd "$(dirname "$0")"

REDBEAN_URL="https://redbean.dev/redbean-latest.com"
OUT="picsort.com"
BASE=".redbean-base.com"

if [[ ! -f "$BASE" ]]; then
  echo "-> downloading redbean..."
  curl -fsSL "$REDBEAN_URL" -o "$BASE"
  chmod +x "$BASE"
fi

echo "-> assembling $OUT"
cp "$BASE" "$OUT"
chmod +x "$OUT"

# fullmoon and exif live under .lua/ so `require` finds them
cp src/exif.lua src/.lua/exif.lua

# zip is appended in place; -j would flatten paths, we want them preserved
( cd src && zip -qr "../$OUT" .init.lua .lua exif.lua static )

echo "-> built $OUT ($(du -h "$OUT" | cut -f1))"
