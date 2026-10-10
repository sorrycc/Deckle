#!/usr/bin/env bash
# Builds the Rust core and the Swift app, then assembles and signs
# build/Deckle.app. Usage: scripts/bundle.sh [debug|release]   (default: release)
# DECKLE_OUT and DECKLE_BUNDLE_ID build a second copy with settings of its own,
# for trying changes while the everyday Deckle keeps running.
# SIGN_IDENTITY signs with a certificate instead of ad hoc, with the hardened
# runtime and the update feed. BUILD sets CFBundleVersion (default: the commit
# count).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${DECKLE_OUT:-$ROOT/build}"
APP="$OUT/Deckle.app"
BUNDLE_ID="${DECKLE_BUNDLE_ID:-dev.sorrycc.deckle}"
# The one version number, from [workspace.package] in Cargo.toml.
VERSION="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml")"
# Sparkle compares CFBundleVersion, which must only go up.
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD)}"
IDENTITY="${SIGN_IDENTITY:--}"
# Only Developer ID builds of the everyday Deckle have a feed, so dev builds
# and second copies never replace themselves with a release.
UPDATES=""
if [ "$IDENTITY" != "-" ] && [ -z "${DECKLE_BUNDLE_ID:-}" ]; then
    [ -s "$ROOT/scripts/sparkle-public-key" ] || { echo "scripts/sparkle-public-key is missing" >&2; exit 1; }
    UPDATES="    <key>SUFeedURL</key><string>https://sorrycc.github.io/Deckle/appcast.xml</string>
    <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < "$ROOT/scripts/sparkle-public-key")</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>"
fi

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

cargo_flags=()
[ "$CONFIG" = "release" ] && cargo_flags+=(--release)
echo "==> cargo build ($CONFIG)"
cargo build --manifest-path "$ROOT/Cargo.toml" --workspace "${cargo_flags[@]}"
RUST_OUT="$ROOT/target/$CONFIG"

echo "==> swift build ($CONFIG)"
SWIFT_OUT="$(swift build --package-path "$ROOT/app" -c "$CONFIG" --show-bin-path)"
# SwiftPM doesn't track the Rust static library, so a Rust-only change would
# not relink. Removing the executable forces the link step.
rm -f "$SWIFT_OUT/Deckle"
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -L"$RUST_OUT" -Xlinker -dead_strip \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Deckle</string>
    <key>CFBundleDisplayName</key><string>Deckle</string>
    <key>CFBundleExecutable</key><string>Deckle</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>Deckle</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 chencheng. MIT License.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <!-- Fonts that come with the app, under Resources/Fonts: LXGW WenKai Lite. -->
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>CFBundleDocumentTypes</key><array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
$UPDATES
</dict>
</plist>
PLIST

cp "$SWIFT_OUT/Deckle" "$APP/Contents/MacOS/Deckle"
# Debug builds keep their symbols for the debugger.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Deckle"
cp "$ROOT/app/Resources/Deckle.icns" "$APP/Contents/Resources/Deckle.icns"
# The usage guide, which Help > Deckle Help opens in a tab.
cp "$ROOT/docs/usage.md" "$APP/Contents/Resources/Deckle Help.md"
# Bundled files the app reads at run time, such as the diagram renderer.
if [ -d "$ROOT/app/Resources/Bundled" ]; then
    cp -R "$ROOT/app/Resources/Bundled/." "$APP/Contents/Resources/"
fi

# Sparkle's XPC services are only for sandboxed apps, which Deckle isn't.
ditto "$SWIFT_OUT/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/app/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/LICENSE-Sparkle.txt"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

# Notarization wants every piece of nested code signed before its container.
echo "==> signing ($IDENTITY)"
sign_flags=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && sign_flags+=(--options runtime --timestamp)
sign() { codesign "${sign_flags[@]}" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
