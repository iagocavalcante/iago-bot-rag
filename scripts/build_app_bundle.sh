#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/.build/WhatsAppBot.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/AppResources/AppIcon.iconset"
ICON_1024="$ROOT_DIR/AppResources/AppIcon-1024.png"
PLIST_TEMPLATE="$ROOT_DIR/AppResources/Info.plist"
BIN_PATH="$BUILD_DIR/WhatsAppAutoReply"

echo "Building release binary..."
swift build -c release

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "Generating logo PNG..."
swift "$ROOT_DIR/scripts/generate_logo.swift" "$ICON_1024"

echo "Generating AppIcon.icns..."
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_1024" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_1024" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_1024" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_1024" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_1024" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_1024" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_1024" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_1024" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_1024" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_1024" "$ICONSET_DIR/icon_512x512@2x.png"

echo "Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/WhatsAppAutoReply"
chmod +x "$MACOS_DIR/WhatsAppAutoReply"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns"

echo "App bundle ready:"
echo "$APP_DIR"
