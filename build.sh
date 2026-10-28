#!/bin/bash
# Builds build/Screen Stitch.app. Pass --install to copy it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

app="build/Screen Stitch.app"
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/AppIcon.iconset

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  ScreenStitch.swift -o "$app/Contents/MacOS/ScreenStitch"
cp Info.plist "$app/Contents/Info.plist"

swiftc -O make-icon.swift -o build/make-icon
build/make-icon build/icon.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "$HOME/Applications/Screen Stitch.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed ~/Applications/Screen Stitch.app"
fi
