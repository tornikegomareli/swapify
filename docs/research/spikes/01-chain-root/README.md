# Spike 01: chain-root patching

Question: if an app is built with `-enable-implicit-dynamic`, can we reload an edited file by
compiling it unchanged and copying each new `$s...TX` chain root into the old one?

Result (iOS 27.2 simulator, Xcode 27.2): yes. One `load` changed a SwiftUI `body` (new modifier),
a non-final class method and a `private` free function. `@State` kept its value.
`dlopen` took 2.8 ms.

Run: `./build.sh`, install `build/Demo.app`, launch it with
`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$PWD/build/HotAgent.dylib`, then send
`load <abs path to build/patch/patch_v2.dylib>` to `127.0.0.1:8899`.
