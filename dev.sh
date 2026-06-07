#!/usr/bin/env bash
# dev.sh — rebuild and hot-restart AgentShot from dist/ (no /Applications install needed).
#
# Why run from dist/ instead of /Applications:
#   - bundle path + identity stays stable across rebuilds -> TCC grants persist
#   - no need to cp/ditto between builds
#   - just ./dev.sh, then look for 📸 in the menubar
#
# First time only:
#   open dist/AgentShot.app
#   Grant Accessibility + Screen Recording in System Settings, then ./dev.sh

set -euo pipefail
cd "$(dirname "$0")"

pkill -f "dist/AgentShot.app/Contents/MacOS/AgentShot" 2>/dev/null || true
sleep 0.4
./build.sh
open dist/AgentShot.app
echo "✓ AgentShot restarted — look for 📸 in the menubar"
