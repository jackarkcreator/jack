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
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$APPDIR/Contents/Frameworks"

echo "==> Compile universal binary (links vendored Sparkle.framework)"
# All app sources except the standalone icon-renderer tool.
APP_SRCS=()
for f in "$DIR"/Sources/*.swift; do
  [ "$(basename "$f")" = "makeicon.swift" ] && continue
  APP_SRCS+=("$f")
done
SPARKLE_FLAGS=(-F "$DIR/Frameworks" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
# FoundationModels (Ask) is macOS 26+ — weak-link so Jack still launches on older macOS.
FM_FLAGS=(-Xfrontend -disable-autolink-framework -Xfrontend FoundationModels
          -Xlinker -weak_framework -Xlinker FoundationModels)
swiftc -O -target arm64-apple-macos11  "${APP_SRCS[@]}" "${SPARKLE_FLAGS[@]}" "${FM_FLAGS[@]}" -o "$BUILD/jack-arm64"
swiftc -O -target x86_64-apple-macos11 "${APP_SRCS[@]}" "${SPARKLE_FLAGS[@]}" "${FM_FLAGS[@]}" -o "$BUILD/jack-x86_64"
lipo -create "$BUILD/jack-arm64" "$BUILD/jack-x86_64" -o "$APPDIR/Contents/MacOS/$APP"
chmod +x "$APPDIR/Contents/MacOS/$APP"

echo "==> Embed Sparkle.framework"
cp -R "$DIR/Frameworks/Sparkle.framework" "$APPDIR/Contents/Frameworks/"

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

echo "==> Codesign (Sparkle innards first — notary rejects unsigned framework pieces — then the app)"
SPK="$APPDIR/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$SIGN_ID" -o runtime --timestamp --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$SIGN_ID" -o runtime --timestamp --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$SIGN_ID" -o runtime --timestamp "$SPK/Versions/B/Autoupdate"
codesign -f -s "$SIGN_ID" -o runtime --timestamp "$SPK/Versions/B/Updater.app"
codesign -f -s "$SIGN_ID" -o runtime --timestamp "$SPK"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "==> Done: $APPDIR"
