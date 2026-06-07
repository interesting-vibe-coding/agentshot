#!/usr/bin/env bash
# Build AgentShot.app — a menubar-only macOS app, zero third-party deps.
# Single-file Swift, compiled directly with swiftc (no SwiftPM needed).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AgentShot"
BUNDLE_ID="dev.doabit.agentshot"
SRC="Sources/AgentShot/main.swift"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> compiling (swiftc -O)"
mkdir -p "$DIST"
swiftc -O -o "$DIST/$APP_NAME" "$SRC" \
    -framework Cocoa -framework ImageIO -framework Carbon -framework UniformTypeIdentifiers

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$DIST/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>      <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>          <string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <!-- menubar-only: no Dock icon, no app switcher entry -->
    <key>LSUIElement</key>              <true/>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign so the global hotkey + screencapture launch work cleanly.
echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> done: $APP"
echo "    open $APP   # launch (menubar icon appears top-right)"
