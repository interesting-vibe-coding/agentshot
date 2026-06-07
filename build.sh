#!/usr/bin/env bash
# Build AgentShot.app — menubar-only macOS app, zero third-party deps.
#
# Primary build uses clang + Objective-C (Sources/AgentShot/AgentShot.m), which
# compiles cleanly even when this machine's Swift toolchain is mismatched.
# A functionally identical Swift version lives at Sources/AgentShot/main.swift;
# build it instead by setting USE_SWIFT=1 (requires a healthy swiftc/SDK).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AgentShot"
BUNDLE_ID="dev.doabit.agentshot"
DIST="dist"
APP="$DIST/$APP_NAME.app"
mkdir -p "$DIST"

if [[ "${USE_SWIFT:-0}" == "1" ]]; then
    echo "==> compiling (swiftc -O)"
    swiftc -O -o "$DIST/$APP_NAME" "Sources/AgentShot/main.swift" \
        -framework Cocoa -framework ImageIO -framework Carbon -framework UniformTypeIdentifiers -framework ServiceManagement
else
    echo "==> compiling (clang -fobjc-arc -O2)"
    clang -fobjc-arc -O2 -o "$DIST/$APP_NAME" "Sources/AgentShot/AgentShot.m" \
        -framework Cocoa -framework ImageIO -framework Carbon -framework UniformTypeIdentifiers -framework ServiceManagement
fi

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

# Sign with a STABLE identity when available, else fall back to ad-hoc.
#
# Ad-hoc (`codesign -s -`) gives a new CDHash every build, and macOS TCC binds
# the Accessibility grant to that CDHash — so every rebuild silently loses the
# permission. A stable self-signed identity makes TCC match on the certificate
# instead, so the grant survives rebuilds. Create it once: ./tools/setup-dev-cert.sh
# CI has no such identity and just uses ad-hoc (end users grant once anyway).
DEV_ID="AgentShot Dev (local)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID"; then
    echo "==> codesign (stable dev identity: $DEV_ID)"
    codesign --force --deep --sign "$DEV_ID" "$APP" || echo "   (codesign failed)"
else
    echo "==> ad-hoc codesign (no dev identity — run ./tools/setup-dev-cert.sh for stable grants)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"
fi

# Strip quarantine so Gatekeeper doesn't block it on first open.
# Do NOT re-sign after stripping — extra signing invalidates TCC identity
# and causes macOS to repeatedly ask for Accessibility/Screen Recording.
xattr -cr "$APP" 2>/dev/null || true

echo "==> done: $APP"
echo "    open $APP                              # launch (menubar icon, top-right)"
echo "    $APP/Contents/MacOS/$APP_NAME --selftest IMG.png   # verify compression pipeline"
