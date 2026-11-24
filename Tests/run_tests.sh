#!/bin/bash
# Runs AlwaysUp's end-to-end self-test.
# Quits the running AlwaysUp first (so two copies don't fight) and relaunches it afterwards.
# Needs passwordless mode. Never touches Wi-Fi, Bluetooth or the screen; briefly mutes the speakers.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/tests"
rm -rf "$OUT"; mkdir -p "$OUT/support"
TARGET="$(uname -m)-apple-macos13.0"
FW="-framework AppKit -framework SwiftUI -framework IOKit -framework CoreWLAN -framework ServiceManagement -framework UserNotifications -framework CoreAudio"

make_app() {  # name bundle-id
  mkdir -p "$OUT/$1.app/Contents/MacOS"
  cat > "$OUT/$1.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string><key>CFBundleExecutable</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>$1</string></dict></plist>
PLIST
}

echo "Building test apps…"
make_app selftest local.alwaysup.selftest
make_app Dummy local.alwaysup.dummy
mkdir -p "$OUT/src" && cp Tests/SelfTest.swift "$OUT/src/main.swift"
if ! swiftc -swift-version 5 -target "$TARGET" $FW $(ls Sources/*.swift | grep -v main.swift) "$OUT/src/main.swift" \
  -o "$OUT/selftest.app/Contents/MacOS/selftest" 2> "$OUT/build.log"; then
  grep error "$OUT/build.log"; exit 1
fi
swiftc -swift-version 5 -target "$TARGET" -framework AppKit Tests/Dummy.swift -o "$OUT/Dummy.app/Contents/MacOS/Dummy"
codesign -fs - "$OUT/selftest.app" "$OUT/Dummy.app" 2>/dev/null

SOCK="$PWD/$OUT/docker.sock"
python3 Tests/fake_docker.py "$SOCK" & DOCKER_PID=$!
WAS_RUNNING=0
if pgrep -x AlwaysUp >/dev/null; then
  WAS_RUNNING=1
  pkill -x AlwaysUp; while pgrep -x AlwaysUp >/dev/null; do sleep 0.2; done
fi
cleanup() {
  kill $DOCKER_PID 2>/dev/null || true
  pkill -f "$OUT/Dummy.app" 2>/dev/null || true
  defaults delete local.alwaysup.selftest >/dev/null 2>&1 || true
  if [[ $WAS_RUNNING == 1 ]]; then open -a AlwaysUp || true; fi
}
trap cleanup EXIT
sleep 0.5

DOCKER_HOST="unix://$SOCK" ALWAYSUP_SUPPORT_DIR="$PWD/$OUT/support" ALWAYSUP_QUIET=1 DUMMY_APP="$PWD/$OUT/Dummy.app" \
  "$OUT/selftest.app/Contents/MacOS/selftest"
