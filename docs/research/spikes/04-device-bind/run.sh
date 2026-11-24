#!/bin/zsh
# Runs spike 04 on the device with no debugger: installs Bind.app, copies patch_v2 and patch_v3
# into the app's tmp/, runs `--test bind` (v1 checks, load v2, checks, load v3, checks) and
# `--test dataconst`, then uninstalls the app. Needs the phone unlocked. Run ./build.sh first.
set -uo pipefail
cd "${0:A:h}"
zmodload zsh/datetime
UDID=${UDID:-00008160-000A51191083400A}
BID=dev.swapify.spike.device
APP=build/DerivedData/Build/Products/Debug-iphoneos/Bind.app
LOGS=build/logs
mkdir -p $LOGS

xcrun devicectl device install app --device $UDID $APP | grep -E "App installed|ERROR"
for v in v2 v3; do
    t=$EPOCHREALTIME
    xcrun devicectl device copy to --device $UDID --source build/patches/$v/patch_$v.dylib \
        --destination tmp/patch_$v.dylib --domain-type appDataContainer --domain-identifier $BID -q
    printf "copy patch_%s.dylib (%s bytes) to the app: %.0f ms\n" $v $(stat -f %z build/patches/$v/patch_$v.dylib) \
        $(( (EPOCHREALTIME - t) * 1000 ))
done
for test in bind dataconst; do
    xcrun devicectl device process launch --device $UDID --console --terminate-existing $BID -- --test $test \
        > $LOGS/$test.log 2>&1
    grep -E "SPIKE|terminated|ERROR|Locked" $LOGS/$test.log
done
[[ ${KEEP_APP:-0} == 1 ]] || xcrun devicectl device uninstall app --device $UDID $BID
