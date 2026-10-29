#!/bin/bash
# Builds build/Screen Stitch.app. Pass --install to copy it into ~/Applications (or the folder given after it),
# quitting and reopening a running copy.
set -euo pipefail
cd "$(dirname "$0")"

# The certificate from make-signing-cert.sh gives every build the same identity, so macOS keeps its Screen
# Recording and microphone permissions; without it, builds are signed ad hoc. Installing from a terminal offers to
# create it once, and .no-signing-cert records a "no".
identity="Screen Stitch Local Signing"
if [[ "${1:-}" == "--install" && -t 0 && ! -e .no-signing-cert ]] && ! security find-certificate -c "$identity" >/dev/null 2>&1; then
  echo "macOS forgets Screen Recording permission each time an ad hoc signed app is rebuilt."
  read -r -p "Create a local signing certificate (adds one to your login keychain) so it survives updates? [y/N] " answer ||
    answer=""
  if [[ "$answer" =~ ^[Yy] ]]; then
    ./make-signing-cert.sh
  else
    touch .no-signing-cert
    echo "OK, signing ad hoc. Run ./make-signing-cert.sh any time to set it up."
  fi
fi

app="build/Screen Stitch.app"
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/AppIcon.iconset

swiftc -O -wmo -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  Sources/*/*.swift -o "$app/Contents/MacOS/ScreenStitch"
cp Info.plist "$app/Contents/Info.plist"

swiftc -O make-icon.swift -o build/make-icon
build/make-icon build/icon.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

if security find-certificate -c "$identity" >/dev/null 2>&1; then
  codesign --force --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi

if [[ "${1:-}" == "--install" ]]; then
  apps="${2:-$HOME/Applications}"
  target="$apps/Screen Stitch.app"
  executable="$target/Contents/MacOS/ScreenStitch"

  # Quit a running copy first and reopen it afterwards. The app treats SIGTERM like ⌘Q, which macOS refuses while
  # a dialog or sheet is open, so stop rather than force it.
  was_running=false
  if pgrep -f "$executable" >/dev/null; then
    was_running=true
    pkill -TERM -f "$executable" || true
    for _ in $(seq 50); do
      pgrep -f "$executable" >/dev/null || break
      sleep 0.2
    done
    if pgrep -f "$executable" >/dev/null; then
      echo "Screen Stitch didn't quit. Close any open dialog, quit it, and run this again." >&2
      exit 1
    fi
  fi

  mkdir -p "$apps"
  rm -rf "$target"
  cp -R "$app" "$apps/"
  echo "Installed $target"
  if $was_running; then
    open "$target"
    echo "Reopened Screen Stitch"
  fi
fi
