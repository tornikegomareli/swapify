#!/bin/zsh
# Builds the swapify Habits example for the device with swapify's Debug settings plus
# -enable-private-imports, and SwapifyAgent.dylib for arm64 iOS, both signed by the team.
#   UDID=<device> TEAM=<team id> DEBUG_DYLIB=YES|NO ./build.sh
set -euo pipefail
cd "${0:A:h}"
UDID=${UDID:-00008160-000A51191083400A}
TEAM=${TEAM:-539293JFA3}
ROOT=../../../..   # the repository
mkdir -p build/certs

# Habits: the project file is generated into build/, so Examples/Habits stays untouched.
# The bundle ID gets the spike suffix so nothing else on the phone is replaced.
xcodegen generate --spec $ROOT/Examples/Habits/project.yml --project build --quiet
xcodebuild -project build/Habits.xcodeproj -scheme Habits -configuration Debug -destination "id=$UDID" \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=dev.swapify.spike.device.habits \
    ENABLE_DEBUG_DYLIB=${DEBUG_DYLIB:-YES} \
    ARCHS=arm64 EMIT_FRONTEND_COMMAND_LINES=YES COMPILATION_CACHE_ENABLE_CACHING=NO \
    'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports' \
    clean build > build/build.log 2>&1 || { grep -E "error:" build/build.log | head -20; exit 1; }
APP=build/DerivedData/Build/Products/Debug-iphoneos/Habits.app

# The image that holds the Swift code: Habits.debug.dylib, or the executable without it.
IMAGE=$APP/Habits.debug.dylib
[[ -f $IMAGE ]] || IMAGE=$APP/Habits
xcrun dyld_info -exports $IMAGE > build/app-exports.txt
echo "Swift code in ${IMAGE:t}; it exports $(grep -c '_\$s6Habits' build/app-exports.txt) Habits symbols"

# The agent, built as scripts/build-agent.sh builds it for the simulator, but for the device,
# and signed with the certificate that signed the app.
codesign -d --extract-certificates=build/certs/cert $APP 2>/dev/null
SHA1=$(openssl x509 -inform DER -in build/certs/cert0 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -isysroot $SDK \
    -dynamiclib -fobjc-arc -fvisibility=hidden -O2 -Wall -Werror -framework UIKit \
    -install_name @rpath/SwapifyAgent.dylib $ROOT/Agent/*.m -o build/SwapifyAgent.dylib
codesign --force --sign $SHA1 build/SwapifyAgent.dylib
echo "agent built and signed by $SHA1"
