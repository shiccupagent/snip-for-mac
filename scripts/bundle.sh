#!/usr/bin/env bash
# Wraps the SwiftPM binary into Snip.app, signs it, and packs Snip.dmg + Snip.zip into dist/.
# Run on macOS after: swift build -c release --arch arm64 --arch x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
VERSION="${VERSION:-1.0.$BUILD_NUMBER}"
BIN="${BIN:-.build/apple/Products/Release/Snip}"
[ -f "$BIN" ] || BIN=.build/release/Snip
IDENTITY="${SIGN_IDENTITY:--}"

rm -rf dist build/iconset build/dmg
mkdir -p dist build
APP=dist/Snip.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Snip"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# App icon
ICONSET=build/iconset/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Sign. A stable (self-signed) identity lets macOS remember the Screen Recording
# permission across updates; ad-hoc signing ("-") works too but resets it each build.
if ! codesign --force --sign "$IDENTITY" --identifier com.shiccup.snip --timestamp=none "$APP"; then
  echo "::warning::Signing with '$IDENTITY' failed; falling back to ad-hoc signing"
  codesign --force --sign - --identifier com.shiccup.snip "$APP"
fi
codesign --verify --verbose=2 "$APP" || true
codesign -d -r- "$APP" || true

# DMG with a drag-to-Applications shortcut
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Snip" -srcfolder build/dmg -ov -format UDZO dist/Snip.dmg >/dev/null
ditto -c -k --keepParent "$APP" dist/Snip.zip

echo "Built Snip $VERSION ($BUILD_NUMBER)"
ls -lh dist
