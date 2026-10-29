#!/bin/bash
# Builds and runs the tests in Tests/. Any arguments go to the test runner, e.g. `./test.sh --filter Combine`.
# SwiftPM normally does this, but it's broken in some Command Line Tools installs, so this builds the runner with swiftc
# and the Tools' own copy of Swift Testing.
set -euo pipefail
cd "$(dirname "$0")"

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
sed 's/^@main$//' ScreenStitch.swift > build/tests/App.swift
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  -F "$frameworks" -L "$libraries" -plugin-path "$plugins" \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libraries" \
  build/tests/App.swift Tests/*.swift -o build/tests/run
build/tests/run "$@"
