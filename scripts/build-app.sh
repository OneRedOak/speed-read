#!/bin/bash
# Assemble sr.app from the SwiftPM release build.
# Pure-SwiftPM workflow — no Xcode project. Signing/notarization is Phase 3;
# until then the bundle is ad-hoc signed so TCC (Accessibility) grants stick.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/sr"
BUNDLE_DIR="dist/sr.app"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"

cp "$BIN" "$BUNDLE_DIR/Contents/MacOS/sr"

# KeyboardShortcuts ships a resource bundle SwiftPM places next to the binary.
BIN_DIR="$(dirname "$BIN")"
for res in "$BIN_DIR"/*.bundle; do
  [ -e "$res" ] && cp -R "$res" "$BUNDLE_DIR/Contents/Resources/"
done

cat > "$BUNDLE_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>sr</string>
    <key>CFBundleDisplayName</key>       <string>sr</string>
    <key>CFBundleIdentifier</key>        <string>com.patrickellis.sr</string>
    <key>CFBundleExecutable</key>        <string>sr</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Public domain intent; see LICENSE.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS TCC identity is stable across rebuilds.
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "Built $BUNDLE_DIR"
