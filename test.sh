#!/bin/bash
# Builds and runs the tests in Tests/. Any arguments go to the test runner, e.g. `./test.sh --filter Combine`.
# SwiftPM normally does this, but it's broken in some Command Line Tools installs, so this builds the runner with swiftc
# and the Tools' own copy of Swift Testing.
#
# `./test.sh --capture` runs only the tests that record the screen. They need Screen Recording permission, so the runner
# is wrapped as an app signed like Screen Stitch and inherits its permission. Windows flash up while they run; leave the
# Mac alone for a few seconds.
set -euo pipefail
cd "$(dirname "$0")"

capture=false
if [[ "${1:-}" == "--capture" ]]; then
  capture=true
  shift
fi

developer=$(xcode-select -p)
frameworks="$developer/Library/Developer/Frameworks"
libraries="$developer/Library/Developer/usr/lib"
plugins="$developer/usr/lib/swift/host/plugins/testing"
if [[ ! -d "$frameworks/Testing.framework" ]]; then
  echo "Swift Testing isn't in $developer. Install the Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

mkdir -p build/tests
# The app's entry point would clash with the test runner's.
entry=Sources/App/ScreenStitchApp.swift
sed 's/^@main$//' "$entry" > build/tests/ScreenStitchApp.swift
sources=()
for file in Sources/*/*.swift; do
  [[ "$file" == "$entry" ]] || sources+=("$file")
done
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  -F "$frameworks" -L "$libraries" -plugin-path "$plugins" \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libraries" \
  build/tests/ScreenStitchApp.swift "${sources[@]}" Tests/*.swift -o build/tests/run

if ! $capture; then
  build/tests/run "$@"
  exit
fi

identity="Screen Stitch Local Signing"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
  echo "The capture tests need the signing certificate from ./make-signing-cert.sh, and Screen Stitch installed with it" >&2
  echo "and allowed to record the screen." >&2
  exit 1
fi
# The same bundle ID and certificate as the app, so macOS treats it as Screen Stitch. No document types, so it doesn't
# show up in Open With.
runner="build/tests/Screen Stitch Tests.app"
rm -rf "$runner"
mkdir -p "$runner/Contents/MacOS"
cp build/tests/run "$runner/Contents/MacOS/run"
cat > "$runner/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>local.screen-stitch</string>
  <key>CFBundleName</key>
  <string>Screen Stitch Tests</string>
  <key>CFBundleExecutable</key>
  <string>run</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
codesign --force --sign "$identity" "$runner"

# Opened rather than run, so macOS checks the app's permission instead of the terminal's.
# Each test's clip is kept in build/tests/capture.
clips="$PWD/build/tests/capture"
rm -rf "$clips"
mkdir -p "$clips"
log=build/tests/capture.log
rm -f "$log" "$log.err"
touch "$log" "$log.err"
open -W -n --stdout "$log" --stderr "$log.err" --env SCREEN_STITCH_CAPTURE="$clips" "$runner" --args --filter CaptureTests "$@"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$runner" ||
  true
cat "$log.err" "$log"
grep -q "Test run with .* passed" "$log.err" "$log"
