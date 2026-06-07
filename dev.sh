#!/usr/bin/env bash
# dev.sh — rebuild and hot-restart AgentShot at a STABLE /Applications path.
#
# Why /Applications (not dist/) and why this works:
#   - build.sh signs with a stable self-signed identity ("AgentShot Dev (local)"),
#     so TCC matches on the certificate, not the per-build CDHash.
#   - We deploy to ONE fixed path (/Applications) and NEVER re-sign after copy
#     (ditto preserves the signature). Same identity + same path = your
#     Accessibility grant persists across every rebuild. Grant it once, ever.
#   - Running from a per-build path (dist/) or having a second ad-hoc copy around
#     splits the TCC identity and makes the grant "randomly" stop working.
#
# First time only:
#   ./dev.sh
#   Grant Accessibility for AgentShot in System Settings ▸ Privacy ▸ Accessibility.
#   (Never needed again — even after rebuilds.)

set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/AgentShot.app"

# Stop every running copy (any path) so we don't leave a stale instance behind.
pkill -f "AgentShot.app/Contents/MacOS/AgentShot" 2>/dev/null || true
sleep 0.5

./build.sh

# Deploy the freshly (stably) signed build to the fixed path. NO re-sign after.
ditto "dist/AgentShot.app" "$APP"

open "$APP"
echo "✓ AgentShot rebuilt & restarted from $APP — look for 📸 in the menubar"
