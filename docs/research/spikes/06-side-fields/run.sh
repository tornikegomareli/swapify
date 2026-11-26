#!/bin/sh
# Builds and runs the cases of spike 06 on macOS. Usage: ./run.sh [plain|nonfinal|observable] (default: all)
set -eu
cd "$(dirname "$0")"
FLAGS="-Onone -Xfrontend -enable-implicit-dynamic -module-name App -parse-as-library"
mkdir -p build
xcrun clang -c -fno-objc-arc runtime/runtime.m -o build/runtime.o

run() {  # case, source file, extra rewrite arguments
    out=build/$1
    mkdir -p $out
    xcrun swiftc -emit-ir $FLAGS $1/app/$2 -o $out/original.ll
    xcrun swiftc -emit-ir $FLAGS $1/patch/$2 -o $out/edited.ll
    xcrun swiftc -emit-sil $FLAGS $1/patch/$2 -o $out/edited.sil
    python3 -I rewrite.py $out/original.ll $out/edited.ll $out/rewritten.ll --sil $out/edited.sil ${3:-}
    xcrun clang -c -O0 $out/rewritten.ll -o $out/patch.o 2>/dev/null
    xcrun swiftc -emit-library $out/patch.o -o $out/patch.dylib -Xlinker -undefined -Xlinker dynamic_lookup
    xcrun swiftc -Onone -Xfrontend -enable-implicit-dynamic -module-name App -import-objc-header runtime/runtime.h \
        $1/app/$2 $1/app/main.swift build/runtime.o -framework Foundation -o $out/app
    echo "── $1"
    MallocStackLogging=1 leaks --atExit -- $out/app "$PWD/$out/patch.dylib" 2>&1 \
        | grep -v 'implemented in both' | grep -E '^[a-z ,]+[:.]|leaks for'
}
if [ "${1:-plain}" = plain ]; then run plain Counter.swift; fi
if [ "${1:-nonfinal}" = nonfinal ]; then run nonfinal Counter.swift; fi
if [ "${1:-observable}" = observable ]; then run observable Model.swift '--redirect-accessor $s3App5ModelC'; fi
