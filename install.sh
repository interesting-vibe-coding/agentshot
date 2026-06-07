#!/usr/bin/env bash
# AgentShot one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/interesting-vibe-coding/agentshot/main/install.sh | bash
set -euo pipefail

REPO="interesting-vibe-coding/agentshot"
APP="/Applications/AgentShot.app"
URL="https://github.com/${REPO}/releases/latest/download/AgentShot.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "$(uname)" != "Darwin" ]]; then
  echo "AgentShot is macOS-only." >&2; exit 1
fi

echo "→ Downloading AgentShot…"
curl -fsSL "$URL" -o "$TMP/AgentShot.zip"

echo "→ Installing to /Applications…"
ditto -x -k "$TMP/AgentShot.zip" "$TMP/out"
rm -rf "$APP"
cp -R "$TMP/out/AgentShot.app" /Applications/

# AgentShot is ad-hoc signed (free OSS, no Apple Developer ID). Strip the
# quarantine flag so Gatekeeper won't block it after a download.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "→ Launching… (look for the 📸 icon in your menubar)"
open "$APP"
echo "✓ Installed. Press ⌘⇧2 to snip → compress → it's on your clipboard."
