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

# App icon: assets/icon.png (1024x1024) -> AppIcon.icns, built with the stock tools.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Sign with a stable local identity when available so the Screen Recording
# permission survives rebuilds (ad-hoc signatures change every build, and TCC
# treats each one as a brand-new app). Falls back to ad-hoc elsewhere.
IDENTITY="Pratik Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Built $APP (signed: $IDENTITY)"
else
  codesign --force --sign - "$APP"
  echo "Built $APP (signed: ad-hoc)"
fi
