#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BeyondBrightness"
BUILD_DIR="$ROOT_DIR/Build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

clang \
  -fobjc-arc \
  -O2 \
  -framework AppKit \
  -framework Foundation \
  -framework CoreGraphics \
  -framework Metal \
  -framework MetalKit \
  -framework QuartzCore \
  -framework UserNotifications \
  "$ROOT_DIR/Sources/BeyondBrightness/main.m" \
  -o "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

echo "Built $APP_DIR"
