#!/usr/bin/env bash
# Runs Deckle Dev with live reload (go tool mygo dev) beside the everyday
# Deckle, with settings of its own in DECKLE_DATA_DIR, and never updating
# itself.
# Usage: scripts/dev.sh [folder]   the folder opens as a workspace
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DECKLE_DATA_DIR="${DECKLE_DATA_DIR:-$HOME/Library/Application Support/Deckle-dev}"
mkdir -p "$DECKLE_DATA_DIR"
[ $# -eq 0 ] || export DECKLE_WORKSPACE="$(cd "$1" && pwd)"
echo "==> mygo dev (data in $DECKLE_DATA_DIR)"
cd "$ROOT"
exec go tool mygo dev
