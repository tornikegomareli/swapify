#!/bin/zsh
# Builds Spike.app (Debug, automatic signing, SpikePlugin.framework embedded but not linked), and
# libspikeplugin.dylib signed with the same certificate as the app. Output goes to build/.
#   UDID=<device> TEAM=<team id> ./build.sh
set -euo pipefail
cd "${0:A:h}"

UDID=${UDID:-00008160-000A51191083400A}
TEAM=${TEAM:-539293JFA3}
OUT=build
PRODUCTS=$OUT/DerivedData/Build/Products/Debug-iphoneos
mkdir -p $OUT

xcodegen generate --spec project.yml --project $OUT --quiet
xcodebuild -project $OUT/Spike.xcodeproj -scheme Spike -configuration Debug \
    -destination "id=$UDID" -derivedDataPath $OUT/DerivedData \
    DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build

# The SHA-1 of the certificate that signed the app, so the plugins use the same identity.
rm -rf $OUT/certs && mkdir -p $OUT/certs
codesign -d --extract-certificates=$OUT/certs/cert $PRODUCTS/Spike.app 2>/dev/null
SHA1=$(openssl x509 -inform DER -in $OUT/certs/cert0 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
echo "app signed by: $(openssl x509 -inform DER -in $OUT/certs/cert0 -noout -subject) ($SHA1)"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios27.0 -isysroot "$SDK" -dynamiclib Plugin/Plugin.c \
    -install_name @rpath/libspikeplugin.dylib -o $OUT/libspikeplugin.dylib
codesign --force --sign "$SHA1" $OUT/libspikeplugin.dylib

# Negative controls for test 3: an ad hoc signature (what swapify's linker produces in the
# simulator) and the certificate of another team in this keychain, if there is one.
cp $OUT/libspikeplugin.dylib $OUT/libspikeplugin-adhoc.dylib
codesign --force --sign - $OUT/libspikeplugin-adhoc.dylib
APP_TEAM=$(openssl x509 -inform DER -in $OUT/certs/cert0 -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
OTHER=$(security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "\(Apple Development: .*\)"$/\1 \2/p' | sort -u \
    | while read sha name; do
        team=$(security find-certificate -c "$name" -p | openssl x509 -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
        if [[ -n $team && $team != $APP_TEAM ]]; then echo $sha; break; fi
      done)
cp $OUT/libspikeplugin.dylib $OUT/libspikeplugin-otherteam.dylib
if [[ -n $OTHER ]] && timeout 30 codesign --force --sign $OTHER $OUT/libspikeplugin-otherteam.dylib; then
    echo "other-team dylib signed by $OTHER"
else
    rm -f $OUT/libspikeplugin-otherteam.dylib
    echo "no other-team identity could sign; skipping that control"
fi

# The standalone framework product, for the data container copy.
rm -rf $OUT/SpikePlugin.framework
cp -R $PRODUCTS/SpikePlugin.framework $OUT/SpikePlugin.framework
codesign --force --sign "$SHA1" $OUT/SpikePlugin.framework

for f in $PRODUCTS/Spike.app $PRODUCTS/Spike.app/Frameworks/SpikePlugin.framework $OUT/SpikePlugin.framework \
         $OUT/libspikeplugin*.dylib; do
    echo "== $f"
    codesign -dvv "$f" 2>&1 | grep -E '^(Identifier|Authority=Apple Development|TeamIdentifier|Signature size)'
done
codesign -d --entitlements - --xml $PRODUCTS/Spike.app 2>/dev/null | plutil -p - 2>/dev/null || true
