#!/bin/bash
# Build, icon, assemble bundle, and Developer ID sign Jack.app (universal arm64 + x86_64).
set -euo pipefail

APP="Jack"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APPDIR="$BUILD/$APP.app"
SIGN_ID="Developer ID Application: ThinkOpen LLC (7C63B47XSL)"

echo "==> Clean"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

echo "==> Compile universal binary"
# All app sources except the standalone icon-renderer tool.
APP_SRCS=()
for f in "$DIR"/Sources/*.swift; do
  [ "$(basename "$f")" = "makeicon.swift" ] && continue
  APP_SRCS+=("$f")
done
swiftc -O -target arm64-apple-macos11  "${APP_SRCS[@]}" -o "$BUILD/jack-arm64"
swiftc -O -target x86_64-apple-macos11 "${APP_SRCS[@]}" -o "$BUILD/jack-x86_64"
lipo -create "$BUILD/jack-arm64" "$BUILD/jack-x86_64" -o "$APPDIR/Contents/MacOS/$APP"
chmod +x "$APPDIR/Contents/MacOS/$APP"

echo "==> Render icon"
swiftc -O "$DIR/Sources/makeicon.swift" -o "$BUILD/makeicon"
"$BUILD/makeicon" "$BUILD/jack-1024.png"
ICONSET="$BUILD/jack.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z "$s" "$s" "$BUILD/jack-1024.png" --out "$ICONSET/icon_${s}x${s}.png"     >/dev/null
  sips -z "$d" "$d" "$BUILD/jack-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png"  >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/jack.icns"

echo "==> Install Info.plist"
cp "$DIR/Info.plist" "$APPDIR/Contents/Info.plist"

echo "==> Codesign (hardened runtime + secure timestamp)"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "==> Done: $APPDIR"
