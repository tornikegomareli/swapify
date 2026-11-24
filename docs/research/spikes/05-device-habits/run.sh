#!/bin/zsh
# Spike 05 end to end: builds Habits and the agent for the device, runs the reload session
# (session.py) with no debugger, copies the screenshots next to RESULTS.md, and uninstalls the app.
# Needs the phone unlocked and its screen on for the whole session (about a minute).
set -uo pipefail
cd "${0:A:h}"
UDID=${UDID:-00008160-000A51191083400A}
export UDID

./build.sh || exit 1
python3 -I session.py 2>&1 | tee build/session.log
mkdir -p screens
cp build/session/*.png build/session/*.txt screens/
xcrun devicectl device uninstall app --device $UDID dev.swapify.spike.device.habits
