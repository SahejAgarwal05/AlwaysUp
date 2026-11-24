#!/bin/bash
# Builds AlwaysUp.app from source. Needs only Apple's Command Line Tools (no Xcode project).
#   ./build.sh              build build/AlwaysUp.app
#   ./build.sh --install    build, copy to /Applications, launch, add the `alwaysup` command
#   ./build.sh --uninstall  remove the app and everything it installed
#   ./build.sh --dmg        build a universal (Apple Silicon + Intel) app and pack build/AlwaysUp-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
VERSION="1.0"
BIN_DIRS=(/opt/homebrew/bin /usr/local/bin)
SUDOERS=/etc/sudoers.d/alwaysup

case "$MODE" in
  ""|--install|--uninstall|--dmg) ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $MODE (try --help)" >&2; exit 64 ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || { echo "AlwaysUp only runs on macOS." >&2; exit 1; }

if [[ "$MODE" == "--uninstall" ]]; then
  # Quitting normally makes the app resume anything it paused and put sleep back.
  pkill -x AlwaysUp 2>/dev/null && while pgrep -x AlwaysUp >/dev/null; do sleep 0.2; done || true
  rm -rf /Applications/AlwaysUp.app "$HOME/Applications/AlwaysUp.app"
  for dir in "${BIN_DIRS[@]}"; do
    if [[ -L "$dir/alwaysup" && "$(readlink "$dir/alwaysup")" == */AlwaysUp.app/Contents/MacOS/AlwaysUp ]]; then
      rm -f "$dir/alwaysup"
    fi
  done
  if pmset -g | grep -q 'SleepDisabled[[:space:]]*1'; then
    echo "Sleep is still disabled; turning it back on (may ask for your password)."
    sudo pmset -a disablesleep 0
  fi
  if [[ -e "$SUDOERS" ]]; then
    echo "Removing $SUDOERS (may ask for your password)."
    sudo rm -f "$SUDOERS"
  fi
  rm -rf "$HOME/Library/Application Support/AlwaysUp"
  defaults delete local.alwaysup >/dev/null 2>&1 || true
  echo "AlwaysUp removed. If it was set to open at login, macOS drops that entry on its own."
  exit 0
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Install Apple's Command Line Tools and run this again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]]; then
  echo "AlwaysUp needs macOS 13 (Ventura) or newer." >&2; exit 1
fi

APP="build/AlwaysUp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # arch output
  swiftc -O -swift-version 5 -target "$1-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreWLAN -framework ServiceManagement -framework UserNotifications \
    Sources/*.swift -o "$2"
}
if [[ "$MODE" == "--dmg" ]]; then
  # A copy meant for other people's Macs runs on both kinds of processor.
  compile arm64 build/AlwaysUp-arm64
  compile x86_64 build/AlwaysUp-x86_64
  lipo -create build/AlwaysUp-arm64 build/AlwaysUp-x86_64 -output "$APP/Contents/MacOS/AlwaysUp"
  rm -f build/AlwaysUp-arm64 build/AlwaysUp-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/AlwaysUp"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AlwaysUp</string>
  <key>CFBundleDisplayName</key><string>AlwaysUp</string>
  <key>CFBundleIdentifier</key><string>local.alwaysup</string>
  <key>CFBundleExecutable</key><string>AlwaysUp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 AlwaysUp contributors. MIT License.</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>AlwaysUp asks for admin rights to change sleep settings.</string>
</dict>
</plist>
PLIST

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Sign with a stable identity when there is one, so macOS keeps the app's permissions (notifications,
# open at login) across rebuilds. Set ALWAYSUP_SIGN_ID to choose; otherwise the first Developer ID /
# Apple Development certificate in the keychain is used; otherwise an ad-hoc signature.
SIGN_ID="${ALWAYSUP_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development)' | head -1 | awk '{print $2}' || true)"
fi
SIGNED=""
if [[ -n "$SIGN_ID" ]] && codesign --force --options runtime --sign "$SIGN_ID" "$APP" 2>/dev/null; then
  SIGNED=1
  echo "Built $APP (signed with $SIGN_ID)"
else
  codesign --force --sign - "$APP"
  echo "Built $APP (ad-hoc signature)"
fi

if [[ "$MODE" == "--install" ]]; then
  # /Applications needs an admin account; fall back to the per-user Applications folder.
  DEST=/Applications
  if [[ ! -w "$DEST" ]]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
  pkill -x AlwaysUp 2>/dev/null && while pgrep -x AlwaysUp >/dev/null; do sleep 0.2; done || true
  rm -rf "$DEST/AlwaysUp.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/AlwaysUp.app"
  echo "Installed to $DEST and launched. Look for the AlwaysUp icon in the menu bar."
  # Command-line shortcut (`alwaysup run …`), when the folder is writable without sudo.
  LINKED=""
  for dir in "${BIN_DIRS[@]}"; do
    if [[ -d "$dir" && -w "$dir" ]]; then
      ln -sf "$DEST/AlwaysUp.app/Contents/MacOS/AlwaysUp" "$dir/alwaysup"
      echo "Command-line tool: $dir/alwaysup"
      LINKED=1
      break
    fi
  done
  [[ -n "$LINKED" ]] || echo "Command-line tool: $DEST/AlwaysUp.app/Contents/MacOS/AlwaysUp"
fi

if [[ "$MODE" == "--dmg" ]]; then
  DMG="build/AlwaysUp-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp LICENSE "$STAGE/LICENSE.txt"
  cp docs/DMG-README.txt "$STAGE/Read Me First.txt"
  hdiutil create -quiet -volname "AlwaysUp" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  # Notarize when there's a Developer ID signature and a stored notarytool profile
  # (xcrun notarytool store-credentials <name>), named in ALWAYSUP_NOTARY_PROFILE.
  if [[ -n "$SIGNED" && -n "${ALWAYSUP_NOTARY_PROFILE:-}" ]]; then
    codesign --force --sign "$SIGN_ID" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$ALWAYSUP_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Packed $DMG (notarized)"
  else
    echo "Packed $DMG (not notarized: macOS will ask people to approve it, see docs/DMG-README.txt)"
  fi
  shasum -a 256 "$DMG"
fi
