#!/usr/bin/env bash
# Builds a debug copy of Deckle in build/dev and opens it beside the everyday
# Deckle. It has its own bundle id, so its own settings, and never updates
# itself.
# Usage: scripts/dev.sh [files or folders...]   e.g. scripts/dev.sh ~/Notes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/dev/Deckle.app"

DECKLE_OUT="$ROOT/build/dev" DECKLE_BUNDLE_ID=dev.sorrycc.deckle.dev "$ROOT/scripts/bundle.sh" debug

echo "==> opening build/dev/Deckle.app"
if [ $# -gt 0 ]; then
    open -a "$APP" "$@"
else
    open "$APP"
fi
