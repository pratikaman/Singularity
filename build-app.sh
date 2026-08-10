#!/bin/zsh
# Build Singularity.app — plain swiftc, no Xcode project.
# NOTE: -target is required on beta toolchains; without it swiftc stamps a
# too-new minos and LaunchServices refuses to launch the app (error -10825).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Singularity"
APP="$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macos15.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Metal \
  -framework MetalKit \
  -framework ScreenCaptureKit \
  -framework CoreGraphics \
  -framework CoreText \
  -framework ImageIO

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
