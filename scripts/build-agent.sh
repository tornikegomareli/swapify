#!/bin/sh
# Builds SwapifyAgent.dylib, a universal (arm64 + x86_64) iOS simulator dylib.
# Usage: scripts/build-agent.sh [output directory, default .build/agent]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$root/.build/agent"}
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$output"

for arch in arm64 x86_64; do
    xcrun --sdk iphonesimulator clang \
        -target "$arch-apple-ios17.0-simulator" -isysroot "$sdk" \
        -dynamiclib -fobjc-arc -fvisibility=hidden -O2 -Wall -Werror \
        -framework UIKit \
        -install_name @rpath/SwapifyAgent.dylib \
        "$root"/Agent/*.m -o "$output/SwapifyAgent-$arch.dylib"
done
xcrun lipo -create "$output"/SwapifyAgent-arm64.dylib "$output"/SwapifyAgent-x86_64.dylib \
    -output "$output/SwapifyAgent.dylib"
rm "$output"/SwapifyAgent-arm64.dylib "$output"/SwapifyAgent-x86_64.dylib
echo "$output/SwapifyAgent.dylib"
