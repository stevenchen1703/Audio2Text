#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="豆包语音妙记"
EXECUTABLE_NAME="$APP_NAME"
PRODUCT_NAME="Audio2TxtApp"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$DIST_DIR/$APP_NAME-macOS.zip"
VERSION_ID="${VERSION_ID:-$(cat "$ROOT_DIR/VERSION.txt")}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ "$VERSION_ID" =~ ^([0-9]{2})([0-9]{2})([0-9]{2})_v([0-9]+)$ ]]; then
  SHORT_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  BUNDLE_VERSION="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
else
  SHORT_VERSION="1.0.0"
  BUNDLE_VERSION="1"
fi

echo "Building release binary..."
swift build -c release --product "$PRODUCT_NAME"

echo "Assembling app bundle..."
rm -rf "$APP_PATH" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$PRODUCT_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
printf '%s\n' "$VERSION_ID" > "$RESOURCES_DIR/VERSION.txt"
printf '%s\n' "$VERSION_ID" > "$DIST_DIR/VERSION.txt"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.audio2txt.doubao</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Clearing quarantine attributes..."
xattr -cr "$APP_PATH" || true

echo "Signing app bundle with identity: $CODESIGN_IDENTITY"
codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"

echo "Clearing post-signing extended attributes..."
xattr -cr "$APP_PATH" || true

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

echo "Checking Gatekeeper assessment..."
if spctl --assess --type execute --verbose=4 "$APP_PATH"; then
  echo "Gatekeeper assessment passed."
else
  echo "Gatekeeper assessment did not pass. This is expected for ad-hoc signing without Developer ID notarization."
fi

echo "Creating zip..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xattr -c "$ZIP_PATH" || true

echo "Done:"
echo "  $APP_PATH"
echo "  $ZIP_PATH"
