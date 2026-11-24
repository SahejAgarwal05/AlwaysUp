#!/bin/bash
# Runs AlwaysUp's unit tests: the Engine's rules against a fake Mac.
# Fast, needs no admin rights, and changes nothing on this Mac. (Tests/run_tests.sh is the
# slower end-to-end test against the real hardware.)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/unit"
rm -rf "$OUT"; mkdir -p "$OUT/src"
cp Tests/UnitTests.swift "$OUT/src/main.swift"
if ! swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework CoreWLAN -framework ServiceManagement \
  -framework UserNotifications -framework CoreAudio \
  $(ls Sources/*.swift | grep -v main.swift) "$OUT/src/main.swift" -o "$OUT/unittests" 2> "$OUT/build.log"; then
  grep error "$OUT/build.log"; exit 1
fi
ALWAYSUP_QUIET=1 "$OUT/unittests"
