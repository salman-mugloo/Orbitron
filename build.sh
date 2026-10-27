#!/bin/bash
# Builds Orbitron.app (a menu-bar app) into ./build and opens it.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Xcode command line tools first:  xcode-select --install"
  exit 1
fi

swift build -c release

APP="build/Orbitron.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Orbitron "$APP/Contents/MacOS/Orbitron"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Orbitron</string>
  <key>CFBundleDisplayName</key><string>Orbitron</string>
  <key>CFBundleIdentifier</key><string>local.orbitron.fileconverter</string>
  <key>CFBundleExecutable</key><string>Orbitron</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Orbitron reads your Finder selection so the wheel can act on the file you have selected.</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it from your own machine.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $(pwd)/$APP"
open "$APP"
