#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) Giffie.app and packages it as a DMG.
#
#   ./scripts/build-dmg.sh            -> build/Giffie-<version>.dmg
#
# Optional environment:
#   VERSION              marketing version (default: contents of VERSION)
#   BUILD_NUMBER         CFBundleVersion (default: 1)
#   ARCHS                architectures to build (default: "arm64 x86_64")
#   CODESIGN_IDENTITY    "Developer ID Application: …" to sign for distribution.
#                        Without it the app is ad-hoc signed.
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                        notarize and staple the DMG (requires CODESIGN_IDENTITY).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Giffie.app"
DMG="$BUILD_DIR/Giffie-$VERSION.dmg"

echo "==> Building Giffie $VERSION ($BUILD_NUMBER) for: $ARCHS"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release --product Giffie "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --product Giffie "${ARCH_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/Giffie"
[[ -x "$BINARY" ]] || { echo "error: built binary not found at $BINARY" >&2; exit 1; }
lipo -info "$BINARY"

echo "==> Assembling $APP"
rm -rf "$APP" "$BUILD_DIR/dmg" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Giffie"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

echo "==> Signing"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating $DMG"
STAGING="$BUILD_DIR/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# hdiutil occasionally fails with "Resource busy" on CI machines; retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "Giffie" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"; then
    break
  fi
  if [[ $attempt == 5 ]]; then echo "error: hdiutil failed" >&2; exit 1; fi
  echo "hdiutil failed (attempt $attempt), retrying…"
  sleep $((attempt * 3))
done
rm -rf "$STAGING"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  fi
fi

hdiutil verify "$DMG"
(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> Done: $DMG"
