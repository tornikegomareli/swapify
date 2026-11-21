#!/bin/zsh
# Builds Demo.app, HotAgent.dylib, and the v2 patch dylib.
set -euo pipefail
cd "${0:A:h}"

TARGET=arm64-apple-ios27.2-simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=build
APP=$OUT/Demo.app
SWIFT_FLAGS=(-sdk "$SDK" -target "$TARGET" -module-name Demo -parse-as-library -Onone -g
             -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports)

mkdir -p "$APP" "$OUT/patch"

# App
xcrun swiftc "${SWIFT_FLAGS[@]}" Demo/App.swift Demo/Types.swift -o "$APP/Demo"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.hotreload.demo</string>
  <key>CFBundleExecutable</key><string>Demo</string>
  <key>CFBundleName</key><string>Demo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>27.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force -s - "$APP"

# Agent
xcrun --sdk iphonesimulator clang -isysroot "$SDK" -target "$TARGET" -dynamiclib -framework CoreFoundation \
    agent/HotAgent.c -o "$OUT/HotAgent.dylib"

# Patch: compile the edited file with the same flags, then link it alone.
(cd "$OUT/patch" && xcrun swiftc "${SWIFT_FLAGS[@]}" -c "$OLDPWD/edits/v2/Types.swift" "$OLDPWD/Demo/App.swift")
xcrun swiftc -sdk "$SDK" -target "$TARGET" -emit-library "$OUT/patch/Types.o" \
    -o "$OUT/patch/patch_v2.dylib" -Xlinker -undefined -Xlinker dynamic_lookup

echo "built $APP, $OUT/HotAgent.dylib, $OUT/patch/patch_v2.dylib"
