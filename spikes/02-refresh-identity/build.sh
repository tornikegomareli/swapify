#!/bin/zsh
# Builds Demo.app, the shared HotAgent.dylib, and a patch dylib from edits/v2/Screen.swift.
set -euo pipefail
cd "${0:A:h}"

TARGET=arm64-apple-ios27.2-simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=build
APP=$OUT/Demo.app
SWIFT_FLAGS=(-sdk "$SDK" -target "$TARGET" -module-name Demo -parse-as-library -Onone -g
             -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports)

mkdir -p "$APP" "$OUT/patch"

xcrun swiftc "${SWIFT_FLAGS[@]}" Demo/App.swift Demo/Screen.swift -o "$APP/Demo"
cp Info.plist "$APP/Info.plist"
codesign --force -s - "$APP"

xcrun --sdk iphonesimulator clang -isysroot "$SDK" -target "$TARGET" -dynamiclib \
    -fobjc-arc -framework UIKit ../../agent/HotAgent.m -o "$OUT/HotAgent.dylib"

(cd "$OUT/patch" && xcrun swiftc "${SWIFT_FLAGS[@]}" -c "$OLDPWD/edits/v2/Screen.swift" "$OLDPWD/Demo/App.swift")
xcrun swiftc -sdk "$SDK" -target "$TARGET" -emit-library "$OUT/patch/Screen.o" \
    -o "$OUT/patch/patch_v2.dylib" -Xlinker -undefined -Xlinker dynamic_lookup
