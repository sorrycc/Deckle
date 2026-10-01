#!/usr/bin/env bash
# Turns app/Resources/Deckle-1024.png into app/Resources/Deckle.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/Resources/Deckle-1024.png"
SET="$(mktemp -d)/Deckle.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/app/Resources/Deckle.icns"
echo "$ROOT/app/Resources/Deckle.icns"
