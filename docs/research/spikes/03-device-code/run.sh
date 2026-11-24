#!/bin/zsh
# Reproduces every measurement in RESULTS.md. Needs an unlocked phone (SpringBoard refuses launches
# while it is locked). Run ./build.sh first.
set -euo pipefail
cd "${0:A:h}"
UDID=${UDID:-00008160-000A51191083400A}
export UDID

xcrun devicectl device install app --device $UDID build/DerivedData/Build/Products/Debug-iphoneos/Spike.app

# Tests 1 and 2: code at run time, each test in its own launch, without and with LLDB attached.
python3 -I run.py --both 1a 1b 1c 1d 1e
python3 -I run.py --dbg 2cave 2region-dbg 2region-app 2region-notouch 2region-big 2region-app+wait

# Test 3: dlopen from the data container, and from the app bundle as the control.
python3 -I run.py --prepare-dlopen
python3 -I run.py --both 3tmp 3lib 3dylib 3adhoc 3otherteam 3bundle
python3 -I run.py --dbg 3patch

# Test 4: transport. devicectl copies (work while locked), then TCP in both directions.
python3 -I transport/measure.py devicectl $UDID dev.swapify.spike.device
zsh transport/tcp.sh
# iproxy needs usbmuxd to see the phone; on this setup `idevice_id -l` and `idevice_id -n` list nothing.

xcrun devicectl device uninstall app --device $UDID dev.swapify.spike.device
