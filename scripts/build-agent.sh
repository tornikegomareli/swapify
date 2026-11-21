#!/bin/sh
# Builds SwapifyAgent.dylib for the arm64 iOS simulator (Apple silicon).
# The patcher writes arm64 jumps, so there is no x86_64 slice.
# Usage: scripts/build-agent.sh [output directory, default .build/agent]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$root/.build/agent"}
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$output"

xcrun --sdk iphonesimulator clang \
    -target arm64-apple-ios17.0-simulator -isysroot "$sdk" \
    -dynamiclib -fobjc-arc -fvisibility=hidden -O2 -Wall -Werror \
    -framework UIKit \
    -install_name @rpath/SwapifyAgent.dylib \
    "$root"/Agent/*.m -o "$output/SwapifyAgent.dylib"
echo "$output/SwapifyAgent.dylib"
