#!/usr/bin/env bash
# Adds a release to the Sparkle appcast on gh-pages, which copies of Deckle
# 0.1, the AppKit app, check: the notarized app as a zip, signed with the
# Sparkle key, uploaded to the release. Run by the Release workflow after
# `mygo build`, with SPARKLE_PRIVATE_KEY set.
# Usage: scripts/sparkle-bridge.sh <Deckle.app>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
VERSION="$(jq -r .version "$ROOT/mygo.json")"
TAG="v$VERSION"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
DIST="$ROOT/build/sparkle"
ZIP="$DIST/Deckle-$VERSION.zip"
rm -rf "$DIST"; mkdir -p "$DIST"

# The disk image was notarized; its ticket covers the app inside.
xcrun stapler staple -q "$APP" || true
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> signing the update with Sparkle's key"
SPARKLE_VERSION=2.10.0
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJ -C "$DIST" ./bin/sign_update
signature="$("$DIST/bin/sign_update" --ed-key-file - "$ZIP" <<<"$SPARKLE_PRIVATE_KEY")"

gh release upload "$TAG" "$ZIP" --clobber
NOTES_FILE="$DIST/notes.md"
"$ROOT/scripts/release-notes.sh" "$VERSION" > "$NOTES_FILE"

# The appcast goes onto gh-pages with plumbing, so nothing is checked out.
echo "==> updating the appcast"
git -C "$ROOT" fetch --quiet origin gh-pages || true
APPCAST="$DIST/appcast.xml"; parent=(); entries=""
if git -C "$ROOT" rev-parse --verify --quiet origin/gh-pages >/dev/null; then
    parent=(-p origin/gh-pages)
    git -C "$ROOT" show origin/gh-pages:appcast.xml > "$APPCAST" 2>/dev/null || rm -f "$APPCAST"
    entries="$(git -C "$ROOT" ls-tree origin/gh-pages | grep -v $'\tappcast.xml$' || true)"
fi
URL="https://github.com/sorrycc/Deckle/releases/download/$TAG/Deckle-$VERSION.zip"
/usr/bin/python3 "$ROOT/scripts/appcast.py" "$APPCAST" "$VERSION" "$BUILD" "$URL" "$signature" "$NOTES_FILE"
blob="$(git -C "$ROOT" hash-object -w "$APPCAST")"
tree="$(printf '%s\n100644 blob %s\tappcast.xml\n' "$entries" "$blob" | sed '/^$/d' | git -C "$ROOT" mktree)"
commit="$(git -C "$ROOT" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "Add Deckle $VERSION to the appcast")"
git -C "$ROOT" push --quiet origin "${commit}:refs/heads/gh-pages"
echo "==> Deckle $VERSION is in the appcast"
