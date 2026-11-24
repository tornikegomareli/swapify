#!/bin/zsh
# Builds Bind.app for the device with swapify's Debug settings plus -enable-testing and
# -enable-private-imports (project.yml), keeps the build log for the patch pipeline, and lists
# what the app exports. Then builds the patches from edits/v2 and edits/v3 (patch.py).
#   UDID=<device> ./build.sh
set -euo pipefail
cd "${0:A:h}"
UDID=${UDID:-00008160-000A51191083400A}
OUT=build
mkdir -p $OUT

xcodegen generate --spec project.yml --project $OUT --quiet
xcodebuild -project $OUT/Bind.xcodeproj -scheme Bind -configuration Debug -destination "id=$UDID" \
    -derivedDataPath $OUT/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    clean build > $OUT/build.log 2>&1 || { grep -E "error:" $OUT/build.log | head -20; exit 1; }
APP=$OUT/DerivedData/Build/Products/Debug-iphoneos/Bind.app
echo "built $APP"

# What the app exports, by symbol kind (python3 -I exports.py prints the table).
xcrun dyld_info -exports $APP/Bind > $OUT/app-exports.txt
xcrun nm -m $APP/Bind > $OUT/app-symbols.txt
python3 -I exports.py $OUT/app-symbols.txt

for version in v2 v3; do
    python3 -I patch.py $version
done
