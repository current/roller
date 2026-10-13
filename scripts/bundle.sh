#!/usr/bin/env bash
# Builds Roller.app (and optionally a .dmg) into ./build.
#
#   scripts/bundle.sh            release build for this Mac's architecture
#   UNIVERSAL=1 scripts/bundle.sh   Apple silicon + Intel
#   DMG=1 scripts/bundle.sh      also make build/Roller-<version>.dmg
#   SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh
#
# Without SIGN_IDENTITY the app is signed ad hoc. macOS ties the
# Accessibility permission to the signature, so after rebuilding an ad hoc
# signed app you may need to remove Roller from Privacy & Security ›
# Accessibility and add it again.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/Roller.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/RollerApp" "$APP/Contents/MacOS/Roller"
cp "$BIN/roller" "$APP/Contents/Resources/bin/roller"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/Resources/bin/roller"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/bin/roller"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"

if [[ "${DMG:-0}" == "1" ]]; then
  DMG_PATH="build/Roller-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "Roller $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG_PATH"
fi
