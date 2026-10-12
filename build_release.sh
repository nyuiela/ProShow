#!/bin/bash
set -euo pipefail

APP_NAME="ProShow"
SCHEME="ProShow"
PROJECT="ProShow.xcodeproj"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROSHOW_BUILD_DIR:-$ROOT/build}"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/Release"
VERSION="1.0.0"
DMG_PATH="$EXPORT_PATH/${APP_NAME}-${VERSION}.dmg"
IDENTITY="${CODESIGN_IDENTITY:-}"
ENTITLEMENTS="$ROOT/ProShow/ProShow.entitlements"
if [[ -n "$IDENTITY" ]]; then
  ENTITLEMENTS="$ROOT/ProShow/ProShowDeveloperID.entitlements"
fi
NOTARY_PROFILE="${AC_NOTARY_PROFILE:-AC_NOTARY_PROFILE}"
SKIP_NOTARIZE=0
SKIP_ARCHIVE=0

usage() {
  cat <<'EOF'
Usage: ./build_release.sh [--skip-notarize] [--skip-archive] [--identity "Developer ID Application: Name (TEAM)"]

Packages a macOS Release build of ProShow 1.0.0 into build/Release/ProShow-1.0.0.dmg.

Without a Developer ID, the script ad-hoc signs with the hardened runtime and
skips Apple notarization. Set AC_NOTARY_PROFILE (keychain profile from
`xcrun notarytool store-credentials`) and CODESIGN_IDENTITY to submit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --skip-archive) SKIP_ARCHIVE=1 ;;
    --identity) IDENTITY="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$BUILD_DIR" "$EXPORT_PATH"
cd "$ROOT"

echo "=== Building ProShow Release ==="
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  build

APP_SRC=$(find "$BUILD_DIR/DerivedData/Build/Products/Release" -maxdepth 2 -name "$APP_NAME.app" | head -n 1)
if [[ -z "$APP_SRC" ]]; then
  echo "Release app not found after build." >&2
  exit 1
fi

if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
  echo "=== Creating Xcode Archive ==="
  if xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$BUILD_DIR/DerivedData"; then
    if [[ -n "${DEVELOPMENT_TEAM:-}" || -n "$IDENTITY" ]]; then
      echo "=== Exporting signed archive ==="
      if xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$ROOT/ExportOptions.plist" \
        -exportPath "$EXPORT_PATH"; then
        APP_SRC="$EXPORT_PATH/$APP_NAME.app"
      else
        echo "exportArchive failed; using local Release .app"
      fi
    else
      echo "No DEVELOPMENT_TEAM / identity — skipping exportArchive"
    fi
  else
    echo "Archive failed (team/signing). Continuing with Release .app"
  fi
fi

APP_DEST="$EXPORT_PATH/$APP_NAME.app"
rm -rf "$APP_DEST"
ditto "$APP_SRC" "$APP_DEST"

echo "=== Mark the binary runnable on OS 26.6 ==="
# Xcode 27 records SDK 27.0. A machine on iOS/macOS 26.6 treats that as a newer OS
# and refuses to open the app. Keep the deployment floor at 14.0 and record 26.6
# as the SDK the binary was built against.
stamp_macos_26() {
  local bin="$1"
  local tmp
  tmp="$(mktemp)"
  if vtool -set-build-version macos 14.0 26.6 -replace -output "$tmp" "$bin"; then
    mv "$tmp" "$bin"
  else
    rm -f "$tmp"
    echo "vtool could not stamp $bin" >&2
    exit 1
  fi
}
while IFS= read -r -d '' macho; do
  if file "$macho" | grep -q 'Mach-O'; then
    stamp_macos_26 "$macho"
  fi
done < <(find "$APP_DEST" -type f -print0)
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$APP_DEST/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 2' "$APP_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$APP_DEST/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$APP_DEST/Contents/Info.plist"

echo "=== Hardened runtime signing ==="
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DEST"
else
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP_DEST"
fi
codesign --verify --verbose=2 "$APP_DEST"

echo "=== Creating DMG ==="
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$APP_DEST" \
  -ov -format UDZO \
  "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "=== Skipping notarization (--skip-notarize) ==="
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "=== Skipping notarization (no keychain profile '$NOTARY_PROFILE') ==="
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE"
else
  echo "=== Submitting to Apple Notarization Service ==="
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "=== Stapling notarization ticket ==="
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler staple "$APP_DEST"
fi

echo "=== Release package ==="
ls -lh "$APP_DEST" "$DMG_PATH"
echo "DMG: $DMG_PATH"
