#!/usr/bin/env bash
# Prints the notes of a version: its section of CHANGELOG.md.
# Usage: scripts/release-notes.sh <version>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/python3 - "$ROOT/CHANGELOG.md" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(rf"^## {re.escape(sys.argv[2])}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if not m:
    sys.exit(f"CHANGELOG.md has no ## {sys.argv[2]} section.")
print(m.group(1).strip())
PY
