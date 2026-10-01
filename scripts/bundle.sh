#!/usr/bin/env bash
# Builds the Rust core and the Swift app, then assembles and ad-hoc signs
# build/Deckle.app. Usage: scripts/bundle.sh [debug|release]   (default: release)
# DECKLE_OUT and DECKLE_BUNDLE_ID build a second copy with settings of its own,
# for trying changes while the everyday Deckle keeps running.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${DECKLE_OUT:-$ROOT/build}"
APP="$OUT/Deckle.app"
BUNDLE_ID="${DECKLE_BUNDLE_ID:-dev.sorrycc.deckle}"
VERSION="0.1.0"

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
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -L"$RUST_OUT" -Xlinker -dead_strip

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>Deckle</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
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
</dict>
</plist>
PLIST

cp "$SWIFT_OUT/Deckle" "$APP/Contents/MacOS/Deckle"
# Debug builds keep their symbols for the debugger.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Deckle"
cp "$ROOT/app/Resources/Deckle.icns" "$APP/Contents/Resources/Deckle.icns"
# Bundled files the app reads at run time, such as the diagram renderer.
if [ -d "$ROOT/app/Resources/Bundled" ]; then
    cp -R "$ROOT/app/Resources/Bundled/." "$APP/Contents/Resources/"
fi

echo "==> ad-hoc signing"
codesign --force --sign - "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
