#!/usr/bin/env bash
# Builds, signs and notarizes Deckle, publishes Deckle-<version>.dmg and .zip
# as a GitHub release, then adds the zip to the Sparkle appcast on gh-pages.
# Runs on a Mac with the Developer ID certificate, or in CI on a v* tag.
# Notarization uses APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID
# when set, else the keychain profile NOTARY_PROFILE (default: deckle-notary).
# The update is signed with SPARKLE_PRIVATE_KEY when set, else the key under
# the keychain account `deckle` (generate_keys --account deckle).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml")"
TAG="v$VERSION"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" BUILD
# A release is the everyday Deckle in build/, whatever the shell has set.
unset DECKLE_OUT DECKLE_BUNDLE_ID
# A version with a pre-release part, such as 0.2.0-beta.1, is a beta.
CHANNEL=""; PRERELEASE=()
[[ "$VERSION" == *-* ]] && { CHANNEL="beta"; PRERELEASE=(--prerelease); }

[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "Commit first." >&2; exit 1; }
[ -z "${GITHUB_REF_NAME:-}" ] || [ "$GITHUB_REF_NAME" = "$TAG" ] || { echo "Tag $GITHUB_REF_NAME doesn't match version $VERSION." >&2; exit 1; }
# In CI the pushed tag already puts HEAD on GitHub, even before its branch is pushed.
[ -n "${GITHUB_REF_NAME:-}" ] || [ -n "$(git -C "$ROOT" branch -r --contains HEAD)" ] || { echo "Push HEAD first: the release is tagged on GitHub." >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "$TAG exists." >&2; exit 1; }

if [ -n "${APPLE_ID:-}" ]; then
    notary_auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
    notary_auth=(--keychain-profile "${NOTARY_PROFILE:-deckle-notary}")
fi

"$ROOT/scripts/bundle.sh" release

DIST="$ROOT/build/dist"; APP="$ROOT/build/Deckle.app"
DMG="$DIST/Deckle-$VERSION.dmg"; ZIP="$DIST/Deckle-$VERSION.zip"
echo "==> making $DMG"
rm -rf "$DIST"; mkdir -p "$DIST/dmg"
ditto "$APP" "$DIST/dmg/Deckle.app"; ln -s /Applications "$DIST/dmg/Applications"
hdiutil create -quiet -volname Deckle -srcfolder "$DIST/dmg" -format UDZO "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# Notarizing the DMG covers the app inside, so both can be stapled after.
# `submit --wait` can crash in its progress output, so poll instead.
echo "==> notarizing"
json_field() { /usr/bin/python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
id="$(xcrun notarytool submit "$DMG" "${notary_auth[@]}" --output-format json | json_field id)"
echo "    submission $id"
status="In Progress"
for _ in $(seq 360); do
    status="$(xcrun notarytool info "$id" "${notary_auth[@]}" --output-format json | json_field status || echo "In Progress")"
    [ "$status" != "In Progress" ] && break
    sleep 30
done
[ "$status" = "Accepted" ] || { echo "Notarization: $status" >&2; xcrun notarytool log "$id" "${notary_auth[@]}" >&2; exit 1; }
xcrun stapler staple -q "$DMG"
xcrun stapler staple -q "$APP"

echo "==> signing the update"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SPARKLE_BIN="$ROOT/app/.build/artifacts/sparkle/Sparkle/bin"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    signature="$("$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP" <<<"$SPARKLE_PRIVATE_KEY")"
else
    signature="$("$SPARKLE_BIN/sign_update" --account deckle "$ZIP")"
fi

# The release goes up before the appcast, so no client sees an item whose
# zip isn't there yet.
echo "==> publishing $TAG"
gh release create "$TAG" "$DMG" "$ZIP" --target "$(git -C "$ROOT" rev-parse HEAD)" \
    --title "Deckle $VERSION" --generate-notes ${PRERELEASE[@]+"${PRERELEASE[@]}"}

# The new appcast goes onto gh-pages with plumbing, so nothing is checked out.
echo "==> updating the appcast"
git -C "$ROOT" fetch --quiet origin gh-pages || true
APPCAST="$DIST/appcast.xml"; parent=(); entries=""
if git -C "$ROOT" rev-parse --verify --quiet origin/gh-pages >/dev/null; then
    parent=(-p origin/gh-pages)
    git -C "$ROOT" show origin/gh-pages:appcast.xml > "$APPCAST" 2>/dev/null || rm -f "$APPCAST"
    entries="$(git -C "$ROOT" ls-tree origin/gh-pages | grep -v $'\tappcast.xml$' || true)"
fi
URL="https://github.com/sorrycc/Deckle/releases/download/$TAG/Deckle-$VERSION.zip"
/usr/bin/python3 "$ROOT/scripts/appcast.py" "$APPCAST" "$VERSION" "$BUILD" "$URL" "$signature" $CHANNEL
blob="$(git -C "$ROOT" hash-object -w "$APPCAST")"
tree="$(printf '%s\n100644 blob %s\tappcast.xml\n' "$entries" "$blob" | sed '/^$/d' | git -C "$ROOT" mktree)"
commit="$(git -C "$ROOT" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "Add Deckle $VERSION to the appcast")"
git -C "$ROOT" push --quiet origin "${commit}:refs/heads/gh-pages"

echo "==> done: https://github.com/sorrycc/Deckle/releases/tag/$TAG"
