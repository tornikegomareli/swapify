#!/bin/sh
# Builds SwapifyAgent.dylib for the arm64 iOS simulator (Apple silicon), and
# SwapifyAgent-iphoneos.dylib for arm64 iOS devices. A simulator slice and a
# device slice are both arm64, so they are two files, not one universal binary.
# The device agent is signed at launch with the identity that signed the app.
# Usage: scripts/build-agent.sh [output directory, default .build/agent]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$root/.build/agent"}
mkdir -p "$output"

build() {
    sdk=$(xcrun --sdk "$1" --show-sdk-path)
    xcrun --sdk "$1" clang \
        -target "$2" -isysroot "$sdk" \
        -dynamiclib -fobjc-arc -fvisibility=hidden -O2 -Wall -Werror \
        -framework UIKit \
        -install_name @rpath/SwapifyAgent.dylib \
        "$root"/Agent/*.m -o "$3"
    echo "$3"
}

build iphonesimulator arm64-apple-ios17.0-simulator "$output/SwapifyAgent.dylib"
build iphoneos arm64-apple-ios17.0 "$output/SwapifyAgent-iphoneos.dylib"
