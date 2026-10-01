#!/usr/bin/env bash
# Builds the Rust core and the Swift app, then assembles and ad-hoc signs
# build/Quill.app. Usage: scripts/bundle.sh [debug|release]   (default: release)
# QUILL_OUT and QUILL_BUNDLE_ID build a second copy with settings of its own,
# for trying changes while the everyday Quill keeps running.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${QUILL_OUT:-$ROOT/build}"
APP="$OUT/Quill.app"
BUNDLE_ID="${QUILL_BUNDLE_ID:-dev.sorrycc.quill}"
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
rm -f "$SWIFT_OUT/Quill"
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -L"$RUST_OUT" -Xlinker -dead_strip

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Quill</string>
    <key>CFBundleDisplayName</key><string>Quill</string>
    <key>CFBundleExecutable</key><string>Quill</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>Quill</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
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

cp "$SWIFT_OUT/Quill" "$APP/Contents/MacOS/Quill"
# Debug builds keep their symbols for the debugger.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Quill"
cp "$ROOT/app/Resources/Quill.icns" "$APP/Contents/Resources/Quill.icns"
# Bundled files the app reads at run time, such as the diagram renderer.
if [ -d "$ROOT/app/Resources/Bundled" ]; then
    cp -R "$ROOT/app/Resources/Bundled/." "$APP/Contents/Resources/"
fi

echo "==> ad-hoc signing"
codesign --force --sign - "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
