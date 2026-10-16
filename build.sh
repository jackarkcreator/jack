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
ICONSET="$BUILD/jack.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# Every size is drawn natively (16/32 px are pixel-snapped), never downscaled from 1024.
"$BUILD/makeicon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/jack.icns"

echo "==> Install Info.plist"
cp "$DIR/Info.plist" "$APPDIR/Contents/Info.plist"

echo "==> Compile asset catalog (v3: Jack teal as the app accent — switches, focus, selection)"
xcrun actool "$DIR/Assets.xcassets" --compile "$APPDIR/Contents/Resources" --platform macosx \
  --minimum-deployment-target 11.0 --accent-color AccentColor \
  --output-partial-info-plist "$BUILD/assets-partial.plist" >/dev/null

echo "==> Build Finder extension (top-level right-click: Convert to PDF with Jack)"
APPEX="$APPDIR/Contents/PlugIns/JackFinder.appex"
mkdir -p "$APPEX/Contents/MacOS"
swiftc -O -parse-as-library -application-extension -target arm64-apple-macos11 \
  "$DIR/FinderExt/JackFinderSync.swift" -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$BUILD/jackfinder-arm64"
swiftc -O -parse-as-library -application-extension -target x86_64-apple-macos11 \
  "$DIR/FinderExt/JackFinderSync.swift" -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$BUILD/jackfinder-x86_64"
lipo -create "$BUILD/jackfinder-arm64" "$BUILD/jackfinder-x86_64" -o "$APPEX/Contents/MacOS/JackFinder"
cp "$DIR/FinderExt/Info.plist" "$APPEX/Contents/Info.plist"
# The extension's version tracks the app's — Finder gets confused by mismatched pairs.
V_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DIR/Info.plist")
V_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DIR/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V_SHORT" -c "Set :CFBundleVersion $V_BUILD" "$APPEX/Contents/Info.plist"

echo "==> Codesign (Sparkle innards first — notary rejects unsigned framework pieces — then the app)"
SPK="$APPDIR/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$SIGN_ID" -o runtime --timestamp --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$SIGN_ID" -o runtime --timestamp --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$SIGN_ID" -o runtime --timestamp "$SPK/Versions/B/Autoupdate"
codesign -f -s "$SIGN_ID" -o runtime --timestamp "$SPK/Versions/B/Updater.app"
codesign -f -s "$SIGN_ID" -o runtime --timestamp "$SPK"
# The appex signs with its sandbox entitlement (Apple requires sandbox for every extension).
codesign -f -s "$SIGN_ID" -o runtime --timestamp \
  --entitlements "$DIR/FinderExt/JackFinder.entitlements" \
  "$APPDIR/Contents/PlugIns/JackFinder.appex"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "==> Done: $APPDIR"
