# Hot reload into the iOS Simulator for a coding agent

Date: 2026-11-21. Machine: arm64, macOS 27.2, Xcode 27.2 (27B52), Swift 6.4.2, iOS 27.2 simulator runtime.

Method: three research slices (A injection mechanics, B Apple internals and `rea`, C agent verification loop). Each slice read primary sources (GitHub source at pinned commits, swiftlang/swift, apple-oss-distributions/dyld, swift-build, Apple release notes) and ran local experiments. The simulator experiments used a throwaway device in a private device set (`simctl --set`), deleted afterwards. The full slice reports, with every citation, are Parts A, B and C below.

Labels: **[ran]** = executed on this machine. **[src]** = read in the cited source. **[inferred]** = conclusion, not verified.

Experiment sources are in `docs/research/experiments/` (`injection/` from slice A, `lldb/` from slice B). Binaries, source clones and the `rea` install stayed in the session scratchpad and can disappear on reboot. Paths in Parts A and B that point to the scratchpad refer to those files.

## Answer

Yes, live reload into a running simulator app is possible without Apple's help, and the critical steps are verified on this machine. Xcode 27.2 has no feature that applies code changes to an app started with Run (B Q5, grep of `IDEIntelligenceChat` and `IDEKit`). Previews does hot swap through its private `XOJIT` engine, but only for processes that Previews launches itself (B Q6).

The working recipe is:

1. Recompile only the edited file with its real frontend command.
2. Link the object into a dylib.
3. `dlopen` the dylib inside the app.
4. Redirect old code to new code.
5. Make the UI render again.
6. Report the result to the agent.

## Verified building blocks

| Fact | Evidence | Number |
|---|---|---|
| A simulator process can `dlopen` a dylib at a host macOS path | A §4 [ran] | warm `dlopen` 0.5-1.6 ms, first 260 ms |
| The linker's ad-hoc signature is enough; an unsigned dylib is rejected | A §4 [ran], dyld `Loader.cpp` L1621-1643 [src] | |
| One-file compile with `swift-frontend -c` | A §1.2 [ran] | 73-95 ms |
| Link one `.o` into a dylib | A §1.2 [ran] | 60-63 ms |
| `@_dynamicReplacement` from a dylib loaded later replaces struct, final, non-final and global functions; newest dylib wins | A §3 [ran] in iOS 27.2 sim | +7% call cost at `-Onone` |
| `-enable-implicit-dynamic` wraps SwiftUI `body` in `DebugReplaceableView`, so the `some View` type can change safely | A §2 SILGen [ran], `SwiftUICore.swiftinterface` [src] | |
| fishhook GOT rebinding plus vtable patch works on iOS 27.2 (needs `-Xlinker -interposable` and `-enable-testing`) | A §1.4 [ran] | |
| `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` inserts a dylib before `main` | A §4 [ran] with `simctl spawn` | |
| LLDB `process load` injects into a running process | A §4 [ran] sim; B Q4 [ran] macOS | 0.48 s attach+load (A); 0.03-0.44 s per load in a warm Python session (B) |
| JIT memory (MAP_JIT, mprotect RX, vm_remap) works in a sim process | A §4 [ran] | |
| Xcode 27.2 ships agent device tools (`DeviceInteractionSynthesize` returns screenshot + hierarchy + log path) | C §3 [src: local strings, plist] | external exposure through `mcpbridge` not verified |

Slices A and B measured very different LLDB CLI costs (0.48 s versus 8.7 s). The setups differ (simulator C binary versus macOS Swift binary). This is not resolved.

## Recommended design

Build three small components. Do not depend on Apple's private Previews services.

```
Claude Code ─ Edit *.swift ─► PostToolUse hook ─► hotd (host daemon, one per simulator)
                                                   1. look up the file's frontend command
                                                   2. swift-frontend -c   → .o       (~90 ms)
                                                   3. clang -dylib        → .dylib   (~60 ms)
                                                        │ Unix socket
                                                        ▼
                                          HotAgent.dylib (inside the app, Debug only)
                                                   4. dlopen + redirect   (~1 ms warm)
                                                   5. re-render, generation += 1
                                                   6. wait until idle     (≥100 ms)
                                                   7. tree snapshot (UIKit + SwiftUI)
                                                        │
                                                        ▼
                         hotd: screenshot, pixel diff, new log lines ─► JSON result to the agent
```

End-to-end estimate from save to verified result: about 0.3-0.4 s on the fast path. This is an [inferred] sum of the measured steps above and the cited verify-loop numbers in C §6. Nothing ran end to end yet.

### 1. `hotd`, the host daemon

- **Compile commands.** Build once with `xcodebuild` and `EMIT_FRONTEND_COMMAND_LINES=YES`. Then parse the per-file `swift-frontend` command from the build log (A §1.1). This works without the Xcode GUI. InjectionNext's default source, SourceKit logging from Xcode, works only for files Xcode has opened, and an agent edits files Xcode never opened.
- **Incompatible settings.** `COMPILATION_CACHE_ENABLE_CACHING` (commands point at `llvmcas://`) and whole-module compilation in Debug (A §1.1).
- **Link.** `clang -dylib -undefined dynamic_lookup` with `-target arm64-apple-ios27.2-simulator` (A §1.2, §4). A macOS-platform dylib is rejected by dyld.
- **Transport.** Unix socket on the host. Simulator apps can connect to host Unix sockets (idb IdleSync does this, C §4).

### 2. `HotAgent.dylib`, inside the app

- **Loading.** Link it in Debug, or insert it with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` (A §4). Use LLDB `process load` only as a fallback for apps that do not include it.
- **Redirect.** See "Swap mechanism" below.
- **Re-render.** Post `INJECTION_BUNDLE_NOTIFICATION`, the same name Inject and InjectionNext use, so existing `@ObserveInjection` views refresh (A §2, C §4). For UIKit, call `injected()` on live instances (A §1.4 step 6).
- **Idle.** Copy idb's IdleSync rules: idle after 100 ms with no main-thread wake longer than 8 ms, no layer animation, no scroll and no ignored input (C §4).
- **Tree.** UIKit through the window and layer walk. SwiftUI through `_UIHostingView._viewDebugData()`, which is declared in the iOS 27.2 SDK (C §4). The `SWIFTUI_VIEW_DEBUG` gate is [inferred].
- **Reply.** `{generation, status, idleSince, tree}`.

### 3. The agent surface

- **One blocking tool**, for example `reload_and_verify({file, expect})`. It returns compile errors, generation, reload status, the changed pixel bounding box, the tree delta, new log lines, crash state and a cropped screenshot path (C §6).
- **A Claude Code `PostToolUse` hook** on `Edit|Write` for `*.swift` files. It calls `hotd` and feeds the result back to the model, so every edit is reloaded and checked without the agent remembering to ask. Confirm the exact hook output format in the Claude Code hooks docs. That format is not part of this research.
- **A skill or `CLAUDE.md` section** that tells the agent what hot reload can and cannot do, so it knows when to run a full rebuild (see "Needs a rebuild").
- **Input** (tap, type, swipe) comes from an existing tool: `axe serve` (about 176 ms for read plus tap, C §2), idb, or Xcode's `DeviceInteractionSynthesize`. Freeze the clock with `simctl status_bar override` before pixel diffs (C §5).

### Swap mechanism

All options need these Debug build flags: `OTHER_SWIFT_FLAGS = -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports`, plus `EMIT_FRONTEND_COMMAND_LINES=YES`.

**Bet: chain-root patching (untested, from source).** With `-enable-implicit-dynamic`, every function gets a prologue that reads a chain root (`...TX`, in writable `__DATA,__data`) and calls `swift_getFunctionReplacement(&root, self)`. The function runs its own body only when `root.implementationFunction == self`. Otherwise it tail-calls the stored pointer ([FunctionReplacement.cpp L19-35](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/FunctionReplacement.cpp#L19-L35), A §3). Pointer authentication is off for arm64 (not arm64e) simulator builds. So the agent dylib can:

1. Compile the edited file **unchanged**, with the same flags.
2. `dlopen` it. Every function in the new image has its own `TX` root, which points to itself.
3. For each `TX` symbol in the new image, find the same-named `TX` in the app image through the Mach-O symbol table, which includes local symbols.
4. Copy the new root's `implementationFunction` into the old root.

If this works, it needs no source rewrite, no `@_dynamicReplacement` attributes, no fishhook, no `-interposable` and no vtable patching. Non-final methods are covered because vtable entries point at the dynamic function and its prologue. `private` functions are covered if their mangled names match, because the private discriminator comes from the file name. I did not find this technique in the sources read, and nobody has run it. It is the first spike.

**Fallback 1: fishhook plus vtable patching.** This is proven in InjectionLite and was reproduced on iOS 27.2 (A §1.4). It needs `-Xlinker -interposable` and `-enable-testing`. It cannot reach `private` symbols.

**Fallback 2: generated `@_dynamicReplacement` source.** This is the compiler-supported path (A §3), and Apple used it for "Legacy Previews Execution" (B Q2). It needs a swift-syntax rewrite that emits one replacement per changed function.

### Needs a rebuild

The agent must rebuild and relaunch for these changes:

- Adding, removing or reordering stored properties (A §1.5).
- Adding or removing methods of non-final classes (vtable layout, A §1.5).
- Changed function signatures. Old callers keep the old mangled name.
- New, renamed or deleted files.
- Top-level code and static initializers. Globals in the reloaded file get new storage.
- Changing an opaque result type outside an erased SwiftUI `body` after first use. This is memory-unsafe (A §2 [ran]).
- Resources, `Info.plist` and entitlements [inferred].

### Ruled out

| Path | Why |
|---|---|
| Drive Apple's XOJIT / Previews against a Run app | Launch-time only, private unversioned XPC (`com.apple.uv.*`, `Ultraviolet.*` plists), `com.apple.private.oop-jit.loader` entitlement, pseudodylib API gated by development mode (B Q6) |
| `dyld_dynamic_interpose` | Body is `return;` in dyld-1378 (A §1.4) |
| Relink the whole module into a new dylib | Duplicates every type and all state; still needs redirection (A §5.1) |
| In-process or remote ORC JIT | Saves only the ~60 ms link; Swift section registration must be redone by hand (A §5.3) |
| LLDB CLI per edit | Cold start up to 8.7 s; only one debugger can attach [inferred] (A §5.4, B Q4) |
| Swap `<App>.debug.dylib` | dyld never unloads Swift images (A §5.1, B Q1) |

### Existing code worth reading before writing ours

- InjectionLite `Reloader.swift`: vtable patching, generics hook, statics, default-argument "unhiding" (A §1.4, §1.5).
- InjectionNext ships an opt-in MCP server and a control socket at `/tmp/InjectionNext-control.sock`, and its client supports screenshot and touch replay (A §1.6). Its tool list was not inspected.
- swift-build `generatePreviewInfo`: how Apple derives a one-file compile command (B Q2 step 4).
- idb IdleSync and `FramebufferSurface`: idle detection and change detection driven by display damage callbacks (C §2, §4).

## First spikes

1. **Chain-root patching.** Pass if a SwiftUI app built with `-enable-implicit-dynamic` shows an edited `body`, a changed `private` helper and a changed non-final method after `dlopen` plus root copy, with no other patching.
2. **Global SwiftUI refresh.** Find a way to re-render all views without `@ObserveInjection` in each one. Apple's agent clears a "modifier cache" after hot swap (`__PREVIEWS_CLEAR_MODIFIER_CACHE_AFTER_HOT_SWAP`, B Q2 step 7), and the mechanism is unknown. Also check if `@State` survives a body swap.
3. **Measured loop.** Measure save to verified JSON on a booted iOS 27.2 simulator. No slice measured `simctl io screenshot` or an in-app tree walk on this Mac.

## Open questions

1. Does chain-root patching work, including `private` functions in the debug dylib's local symbol table?
2. How do we trigger a SwiftUI re-render without per-view opt-in, and does view state survive?
3. Does `SWIFTUI_VIEW_DEBUG` enable `_viewDebugData` on the iOS 27.2 runtime? Only the string's presence in 26.5 is verified (C §4).
4. Can patches link against `@rpath/<App>.debug.dylib` with a two-level namespace instead of the deprecated `-undefined dynamic_lookup` (A §5.1)?
5. Does `xcrun mcpbridge` expose `DeviceInteraction*` to external agents (C §3)?
6. If Xcode already debugs the app, does a second LLDB attach fail (A §5.4)?
7. Is AXe's GPL-3.0 license acceptable if the tool bundles it? Running it as a separate binary is a different case from embedding it (C §2).

Side effect of the research: slice B ran one `npm view` with the real `HOME`. It wrote `~/.npm/_logs/2026-11-21T08_14_33_072Z-debug-0.log` and registry metadata in `~/.npm/_cacache`.


---

## Part A: code-injection mechanics for live Swift reload in the iOS Simulator

Scope: how changed Swift code gets compiled, loaded, and bound into a running simulator app. Xcode Previews internals and the agent verification loop are out of scope.

Date: 2026-11-21. Machine: `uname -m` = `arm64`, macOS 27.2, Xcode 27.2 (27B52), Swift 6.4.2 (`swiftlang-6.4.2.1.9`), iPhoneSimulator SDK 27.2, iOS 27.2 runtime (24B8117).

Labels used below:

- **[src]**: I read it in the cited source file.
- **[ran]**: I ran it on this machine. Commands are in the Appendix.
- **[inferred]**: my conclusion, not verified.

Pinned source revisions (all links below use these commits):

| Short | Repository @ commit |
|---|---|
| IN | johnno1962/InjectionNext @ `b39c9f15cf` |
| IL | johnno1962/InjectionLite @ `a74f69ece8` |
| I3 | johnno1962/InjectionIII @ `f793d95f6b` |
| HR | johnno1962/HotReloading @ `f3a785427f` |
| DK / FH | johnno1962/DLKit @ `b62413f567`, johnno1962/fishhook @ `adc337e921` |
| IJ / HS | krzysztofzablocki/Inject @ `67e3ee9a2b`, johnno1962/HotSwiftUI @ `868e889cf8` |
| SW | swiftlang/swift @ `03902ae424` |
| DY | apple-oss-distributions/dyld @ `fd8d0c4d52` (dyld-1378) |
| SB | swiftlang/swift-build @ `70bff5d0ee` |
| LL | llvm/llvm-project @ `aab5b20337` |

### Summary

- The approach that works today has four steps. Recompile one file with its real frontend command. Link the object into a dylib with `-undefined dynamic_lookup`. `dlopen` it in the app. Rebind the app's GOT entries, patch class vtables, and swizzle ObjC methods. InjectionNext 2.0.x with InjectionLite does this and supports Xcode/iOS 27.
- I reproduced each step in an iOS 27.2 simulator process **[ran]**. A dylib at a host path loads. The linker's ad-hoc signature is enough. fishhook rebinding changes struct, final-class, protocol-witness, and generic calls. Non-final class methods change only after a vtable slot patch.
- `@_dynamicReplacement` with `-enable-implicit-dynamic` is a compiler-supported alternative. A dylib loaded later replaces functions in the running app, including non-final class methods, with no linker flags or fishhook **[ran]**. Cost in a micro benchmark: +7% at `-Onone`. The same flag also makes the compiler wrap SwiftUI `some View` bodies in `DebugReplaceableView` **[ran]**.
- If the concrete type behind a `some` return changes after first use, the result is memory-unsafe with both mechanisms. Callers cache the opaque type metadata **[ran]**. This is why SwiftUI injection needs `AnyView` or `DebugReplaceableView` erasure.
- dyld never unloads images that contain Swift or ObjC **[src]**. Each reload leaks one dylib, which is acceptable for a dev session.

### 1. InjectionIII, HotReloading, InjectionLite, InjectionNext

The projects form one lineage. HotReloading is "the InjectionIII app as a Swift Package" and its README says InjectionNext supersedes it ([HR README L1-7](https://github.com/johnno1962/HotReloading/blob/f3a785427f/README.md#L1-L7)). The InjectionIII README calls InjectionNext its successor ([I3 README L29-34](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L29-L34)). InjectionNext (the Mac app plus a client package) reuses InjectionLite's in-app code for loading and patching ([IL Package.swift L15-20](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Package.swift#L15-L20)).

#### 1.1 Finding the compile command for one file

There are four strategies in the source. None of them uses `-Xfrontend` flags to discover commands. InjectionNext drops `-Xfrontend` and `-driver-*` arguments when it captures them ([IN MonitorXcode.swift L184-185](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/MonitorXcode.swift#L184-L185)).

1. **Build-log grep.** InjectionIII, HotReloading, InjectionLite standalone, and the InjectionNext "Watch Project" fallback use it. The tool gunzips the newest `*.xcactivitylog` files and greps for ` -primary-file <path> ` (Swift) or ` -c <path> ` (C/ObjC) ([IL LogParser.swift L41-47](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/LogParser.swift#L41-L47)). It then rewrites the line so it compiles one primary file. It removes `-o`, per-file outputs, other `-primary-file` arguments, and `-frontend-parseable-output` ([L77-127](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/LogParser.swift#L77-L127)). The command is cached in `/tmp` because Xcode deletes old logs ([IL Recompiler.swift L28-30](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/Recompiler.swift#L28-L30)). HotReloading does the same scan with a generated Perl script ([HR SwiftEval.swift L1009-1018](https://github.com/johnno1962/HotReloading/blob/f3a785427f/Sources/HotReloading/SwiftEval.swift#L1009-L1018)).
   - Since Xcode 16.3 the frontend command lines are not in the log by default. The user must add the user-defined build setting `EMIT_FRONTEND_COMMAND_LINES=YES` ([I3 README L14-24](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L14-L24)). In swift-build this setting makes each Swift driver job print its full frontend command into the build log ([SB TaskProducer.swift L461](https://github.com/swiftlang/swift-build/blob/70bff5d0ee/Sources/SWBTaskConstruction/TaskProducers/TaskProducer.swift#L461), [SB SwiftDriverJobTaskAction.swift L377-387](https://github.com/swiftlang/swift-build/blob/70bff5d0ee/Sources/SWBTaskExecution/TaskActions/SwiftDriverJobTaskAction.swift#L377-L387)).
   - Fallback without the setting: run the module's `builtin-Swift-Compilation` command again, then take that file's `.o` from the build's object directory. This only works for files in the main module ([IL LogParser.swift L48-58](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/LogParser.swift#L48-L58), [IL Recompiler.swift L194-224](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/Recompiler.swift#L194-L224)).
   - Incompatible: `COMPILATION_CACHE_ENABLE_CACHING`, because commands then refer to `llvmcas://`, and whole-module compilation ([IL Recompiler.swift L74-89](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/Recompiler.swift#L74-L89)).
2. **SourceKit logging (InjectionNext default).** The app starts Xcode as a child process with `SOURCEKIT_LOGGING=1` and reads Xcode's stdout ([IN MonitorXcode.swift L66-70](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/MonitorXcode.swift#L66-L70)). For editor requests it parses `key.compilerargs`, which are the per-file arguments SourceKit uses, and stores them per file ([L144-203](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/MonitorXcode.swift#L144-L203)). The request `source.request.indexer.editor-will-save-file` triggers the injection ([L204-213](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/MonitorXcode.swift#L204-L213)). The app then runs `swift-frontend -c -filelist <target files> -primary-file <file> -DDEBUG -DINJECTING` and drops WMO flags ([IN NextCompiler.swift L267-316](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/NextCompiler.swift#L267-L316)). Limit: if Xcode never opened the file, there are no arguments and the injection waits ("Have you viewed it in Xcode?", [L268-271](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/NextCompiler.swift#L268-L271)).
3. **Compiler proxy (InjectionNext, opt-in).** The app renames the toolchain's `swift-frontend` to `swift-frontend.save` and installs a script in its place. The script runs the real compiler and sends every `-c` command line and its environment to the app ([IN FrontendServer.swift L253-292](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/FrontendServer.swift#L253-L292), [swift-frontend.sh L9-12](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/swift-frontend.sh#L9-L12)). This changes the Xcode toolchain on disk.
4. **Bazel.** InjectionLite queries the action graph with `BazelAQueryParser` ([IL Recompiler.swift L44-63](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/Recompiler.swift#L44-L63)).

#### 1.2 Linking the object into a dylib

- Link command ([IL Common.swift L182-191](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Common.swift#L182-L191)): `clang -arch <arch> -Xlinker -dylib -isysroot <sdk> -mios-simulator-version-min=9.0 -L<toolchain>/usr/lib/swift/iphonesimulator -undefined dynamic_lookup -dead_strip -Xlinker -interposable -fobjc-arc ... <object> -o <dylib>`. HotReloading uses the same flags ([HR SwiftEval.swift L601-611](https://github.com/johnno1962/HotReloading/blob/f3a785427f/Sources/HotReloading/SwiftEval.swift#L601-L611)).
- `-undefined dynamic_lookup` leaves references to app symbols unresolved. dyld binds them at `dlopen` time against the images already loaded **[inferred from the flag semantics; confirmed in practice by the experiment in 1.4]**. Xcode 27.2's `ld` prints `-undefined dynamic_lookup is deprecated on iOS-simulator` but still links **[ran]**.
- Code signing: InjectionNext skips `codesign` for `iPhoneSimulator` ([IN NextCompiler.swift L392-393](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/NextCompiler.swift#L392-L393)). InjectionLite signs only on tvOS ([IL Recompiler.swift L235-247](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/Recompiler.swift#L235-L247)). The linker output is already signed: `codesign -dv` shows `flags=0x20002(adhoc,linker-signed)` **[ran]**.
- Timing for a 10-line file **[ran]**: `swift-frontend -c` took 73-95 ms and the `clang` link took 60-63 ms.

#### 1.3 Getting the dylib into the simulator process

This happens in two stages: the injection client loads once per launch, then each change loads a new dylib.

- **Client bootstrap.**
  - InjectionIII: the app calls `Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle")?.load()`, which loads straight from the host path ([I3 README L36-53](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L36-L53)). Inject and HotSwiftUI do this load lazily ([IJ InjectConfiguration.swift L33-71](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/Sources/Inject/InjectConfiguration.swift#L33-L71), [HS HotSwiftUI.swift L35-73](https://github.com/johnno1962/HotSwiftUI/blob/868e889cf8/Sources/HotSwiftUI/HotSwiftUI.swift#L35-L73)).
  - InjectionNext: add the SPM package (compiled only in DEBUG), copy the prebuilt bundles with `copy_bundle.sh`, or add the client dylib as a Debug "Other Linker Flag" ([IN README L73-105](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/README.md#L73-L105)). An ObjC `+load` runs when the image loads. It skips Xcode Previews and test runs, then connects on a background thread ([IN ClientBoot.mm L29-40](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNextC/ClientBoot.mm#L29-L40), [IL InjectionBoot.mm L38-44](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImplC/InjectionBoot.mm#L38-L44)).
  - The client opens TCP to `127.0.0.1:8887` ([IN ClientBoot.mm L52, L72-83](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNextC/ClientBoot.mm#L52-L83), [InjectionClient.h L15-20](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNextC/include/InjectionClient.h#L15-L20)). If no server answers, the client starts InjectionLite standalone mode, which watches files and recompiles inside the app process ([ClientBoot.mm L85-94](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNextC/ClientBoot.mm#L85-L94)).
- **Per change.** For a local client (simulator or Mac), the server sends a `load` command with a path. The path is in the client's `NSTemporaryDirectory()`, which the client reported when it connected ([IN NextCompiler.swift L139-154](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/NextCompiler.swift#L139-L154), [IN InjectionNext.swift L139](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNext/InjectionNext.swift#L139)). For a device, the server sends the bytes (`inject`) and the client writes them to its temporary directory ([InjectionNext.swift L343-354](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNext/InjectionNext.swift#L343-L354)). The client calls `dlopen(path, RTLD_NOW)` ([DK DLKit.swift L74-92](https://github.com/johnno1962/DLKit/blob/b62413f567/Sources/DLKit/DLKit.swift#L74-L92)), patches, and replies `injected` or `failed` ([InjectionNext.swift L286-314](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNext/InjectionNext.swift#L286-L314)). That reply is a ready-made "reload happened" signal for an agent.
- None of the six repositories uses `DYLD_INSERT_LIBRARIES` (`grep -rl` returned no match) **[ran]**.
- In standalone mode the app process itself runs `popen` with `gunzip`, `grep`, `swift-frontend`, and `clang`, and it reads DerivedData logs ([IL LogParser.swift L41-58](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/LogParser.swift#L41-L58), [IL Recompiler.swift L142](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionLite/Recompiler.swift#L142)). This mode requires that simulator apps can run host tools and read the host file system **[inferred: the code depends on it]**.

#### 1.4 Replacing implementations

After `dlopen`, `Reloader.loadAndPatch` runs these steps ([IL Reloader.swift L178-211](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L178-L211)):

1. **Interposing (the main mechanism).** `injectableSymbol` decides from the mangled-name suffix which symbols to rebind ([L552-591](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L552-L591)). It accepts Swift functions, getters, setters, modify coroutines, static and class methods, async functions, and C++. Each accepted symbol in the new dylib is rebound in every app image with fishhook's `rebind_symbols_image` ([L470-498](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L470-L498), [DK Interposing.swift L73-93](https://github.com/johnno1962/DLKit/blob/b62413f567/Sources/DLKit/Interposing.swift#L73-L93)). fishhook rewrites the `S_LAZY_SYMBOL_POINTERS` and `S_NON_LAZY_SYMBOL_POINTERS` sections in `__DATA` and `__DATA_CONST` ([FH fishhook.c L255-269](https://github.com/johnno1962/fishhook/blob/adc337e921/fishhook.c#L255-L269)). Since October 2026 the fork uses `vm_protect(..., VM_PROT_COPY)` on page-aligned ranges, because `mprotect` on `__DATA_CONST` fails on iOS 27 ([FH fishhook.c L111-128](https://github.com/johnno1962/fishhook/blob/adc337e921/fishhook.c#L111-L128), [InjectionNext issue #174](https://github.com/johnno1962/InjectionNext/issues/174)).
   - **Why `-Xlinker -interposable` is required [ran].** With the flag, calls from the app to its own exported Swift functions go through `__stubs` and `__got` entries that have indirect-symbol entries, so fishhook can rewrite them. Without the flag the calls are direct `bl` instructions and there is nothing to rebind.
   - **Internal symbols must also be exported [ran].** Without `-enable-testing`, internal Swift symbols were "private external" and had no stubs, even with `-interposable`. Xcode's `ENABLE_TESTABILITY` passes `-enable-testing` and `-rdynamic` ([SB CoreBuildSystem.xcspec L3789-3803](https://github.com/swiftlang/swift-build/blob/70bff5d0ee/Sources/SWBCore/Specs/CoreBuildSystem.xcspec#L3789-L3803)). The Base project template sets `ENABLE_TESTABILITY = YES` for Debug (local `Base_ProjectSettings.xctemplate/TemplateInfo.plist` L114).
2. **Swift vtable patching.** For each class in the new dylib (`CN` metadata symbols and `OBJC_CLASS_$_`), the code finds older versions with the same name through `objc_copyClassList` ([L294-308](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L294-L308)). It copies every vtable slot that points to an injectable symbol from the new metadata into the old metadata ([L311-402](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L311-L402)).
3. **ObjC swizzling** with `class_replaceMethod` for all instance and class methods ([L405-428](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L405-L428)).
4. **Generic classes.** At startup the code hooks `swift_allocateGenericClassMetadata` to record every specialization, so their vtables can be patched later ([IL Generics.swift L19-25](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Generics.swift#L19-L25), [InjectionBoot.mm L72-74](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImplC/InjectionBoot.mm#L72-L74)).
5. **Key paths.** An optional hook on `swift_getKeyPath` turns on automatically for TCA ([IL KeyPaths.swift L8-29](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/KeyPaths.swift#L8-L29), [InjectionBoot.mm L67-71](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImplC/InjectionBoot.mm#L67-L71)).
6. **Notify.** The code posts `INJECTION_BUNDLE_NOTIFICATION` on the main queue and calls `@objc class func injected()`. For instance-level `injected()`, it sweeps the live object graph to find instances ([IL Sweeper.swift L30-136](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Sweeper.swift#L30-L136)).

`dyld_dynamic_interpose`, the dyld SPI for runtime interposing, does nothing in current dyld: its body is `return;` with a reference to rdar 74287303 ([DY libdyldGlue.cpp L555-560](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/libdyld/libdyldGlue.cpp#L555-L560)). Rewriting the GOT from user code, as fishhook does, is the only way left to rebind at runtime **[inferred from that]**.

**End-to-end reproduction [ran].** I used only fishhook plus about 15 lines of glue, no InjectionNext code, in an iOS 27.2 simulator process.

- Setup: the app was built with `-Onone -enable-testing -Xlinker -interposable`. The patch dylib was built from edited source with the same module name. The glue called `dlopen` and then `rebind_symbols` for each changed function.
- Struct method, final class method, protocol call through an existential, and generic call all returned the new values. Protocol witness thunks call the concrete function through its stub, so no witness table patch was needed.
- The non-final class method kept the old value until I overwrote vtable slot 10 in the old class metadata.
- Without `-interposable`, only the vtable patch had an effect.
- ObjC logged `Class _TtC3App4Base is implemented in both ...`. InjectionLite tells the user to ignore this message ([Reloader.swift L189-191](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L189-L191)).

#### 1.5 Hard limits

- **Stored-property layout.** You cannot add, remove, or reorder stored properties ([IN README L62-64](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/README.md#L62-L64), [I3 README L91-97](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L91-L97)). `Reloader` compares type sizes from the value witness tables before and after `dlopen`. If a size changed, it blocks the first attempt and runs the second attempt anyway ([IL Reloader.swift L117-160](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L117-L160)). The check runs after the dylib is already mapped.
- **Methods of non-final classes.** You cannot add, remove, or reorder them, because the vtable layout is fixed. A change in class size only produces a warning, which suggests making the class `final` ([L334-341](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L334-L341)).
- **Signatures.** You cannot change a function signature ([IN README L62-64](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/README.md#L62-L64)). A new signature has a new mangled name, and old callers still bind the old symbol **[inferred]**.
- **`private` and `fileprivate`.** These symbols are not exported and cannot be interposed directly ([I3 README L100-104](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L100-L104)). In my build, a call to a `private func` compiled to a direct `bl` **[ran]**. Changes reach them only indirectly, through callers in the same file.
- **Default arguments.** Default-argument generators are "private external", so `dlopen` fails with "symbol not found in flat namespace". InjectionLite works around this by "unhiding" the symbols in DerivedData object files ([IL Unhider.swift L8-11](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Unhider.swift#L8-L11), [Reloader.swift L84-91](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L84-L91)).
- **Globals and statics in the injected file.** They get new storage and a new initial value, unless `INJECTION_PRESERVE_STATICS` is set ([IL InjectionImplC.h L27-28](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImplC/include/InjectionImplC.h#L27-L28), [Reloader.swift L126-134, L584-588](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L126-L134)).
- **Works:** `final` and `static` methods, struct and enum methods, and free functions, through interposing ([injectableSymbol L576-590](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L576-L590)). I confirmed this for a struct method and a final class method **[ran]**.
- **Generics.** Generic classes work through the metadata hook. Generic functions work at `-Onone` because callers use the unspecialized symbol **[inferred]**.
- **Top-level code** does not run again. Only functions are replaced **[inferred from the mechanism]**.
- **Files added, renamed, or deleted** are not handled well. Rebuild the app ([I3 README L105-108](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L105-L108)).
- **Re-execution.** The new code must be called again to have a visible effect. Use `injected()`, the notification, or a host type ([I3 README L60-84](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L60-L84)).

#### 1.6 Project status (late 2026, from `git log` and `gh api` [ran])

| Project | Last commit | Latest release | Xcode 26/27 notes |
|---|---|---|---|
| InjectionNext | 2026-09-28 (docs); code 2026-06-15 | 2.0.2RC5 prerelease 2026-11-10; 2.0.1 2026-06-08 | Commit `843e52f` "Xcode/iOS 27 (#162)" on 2026-06-13. 2.0.1 notes say "Change required for Xcode/iOS 27". Issue #165 (fishhook crash on Xcode 27 beta) fixed in 2.0.1. Open: [#178](https://github.com/johnno1962/InjectionNext/issues/178) "Xcode 27.2: copy_bundle.sh makes simulator installs fail" (2026-11-10), #177, #176. |
| InjectionLite | 2026-11-10 | tag 3.0.3 | "Resolve resilient Swift class stubs before patching (#31)" on 2026-09-28. An Xcode 27 popen workaround was added and then reverted (2026-09-30, 2026-10-11). |
| fishhook fork / DLKit / SwiftTrace | 2026-10-10 / 2026-10-11 / 2026-10-09 | DLKit 3.6.1 | Moved to `vm_protect` for iOS 27 (#174). |
| InjectionIII | 2026-10-06 ("2.x sync from InjectionNext including MCP") | 5.2.1RC5, 2026-06-14 | README points to InjectionNext. Log parsing needs `EMIT_FRONTEND_COMMAND_LINES`. |
| HotReloading | 2026-05-25 | v5.1.0 | README: superseded. |
| Inject | 2026-04-29 (Swift 6 concurrency fix) | 1.6.0, 2026-04-14 | Wrapper only. |
| HotSwiftUI | 2026-04-29 | 1.2.5 | Wrapper only. |

InjectionNext also ships an opt-in MCP server and a control socket at `/tmp/InjectionNext-control.sock` ([IN mcp-server/README.md](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/mcp-server/README.md), [ControlServer.swift L14-17](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/ControlServer.swift#L14-L17)). Its client supports screenshot and touch-replay commands ([InjectionNext.swift L368-389](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/Sources/InjectionNext/InjectionNext.swift#L368-L389)).

### 2. Inject and the SwiftUI pattern

- **Role.** Inject is a thin wrapper and InjectionIII or InjectionNext does the actual injection ([IJ README L15](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/README.md#L15)). On first use it loads the injection bundle from `/Applications/InjectionIII.app` or `InjectionNext.app` ([IJ InjectConfiguration.swift L33-71](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/Sources/Inject/InjectConfiguration.swift#L33-L71)).
- **How a reload refreshes a view.**
  1. After patching, the runtime posts `INJECTION_BUNDLE_NOTIFICATION` on the main queue ([IL Sweeper.swift L32-37](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Sweeper.swift#L32-L37)).
  2. `InjectionObserver`, an `ObservableObject`, increments `@Published injectionNumber` when the notification arrives. An animation is optional ([IJ InjectConfiguration.swift L73-91](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/Sources/Inject/InjectConfiguration.swift#L73-L91)).
  3. `@ObserveInjection` is a `DynamicProperty` that holds an `@ObservedObject` reference to the shared observer ([IJ SwiftUI.swift L24-31](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/Sources/Inject/Integrations/SwiftUI.swift#L24-L31)).
  4. SwiftUI invalidates every view that declares this property and runs `body` again. `body` now calls the rebound getter.
  5. Views without the property do not render again until other state changes **[inferred from SwiftUI's invalidation model]**. HotSwiftUI uses the same design ([HS HotSwiftUI.swift L17-33, L93-101](https://github.com/johnno1962/HotSwiftUI/blob/868e889cf8/Sources/HotSwiftUI/HotSwiftUI.swift#L17-L33)).
- **`.enableInjection()`** returns `AnyView(self)` in DEBUG and an inlined `self` in release ([IJ SwiftUI.swift L8-14, L35-43](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/Sources/Inject/Integrations/SwiftUI.swift#L8-L14)).
- **Why erasure is needed.** Adding or removing views changes the concrete type behind `some View`, and that is a memory-layout change ([I3 README L134-141](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L134-L141)). I measured the hazard with Swift's own replacement mechanism **[ran]**. I replaced `makeShape() -> some CustomStringConvertible`, changing the returned type from `Int` to `String`:
  - Patch loaded before the first call: `MemoryLayout.size(ofValue:)` = 16 and `type(of:)` = `String`. This is correct.
  - Patch loaded after the first call: size stayed 8 and `type(of:)` stayed `Int`, while the value printed through `String`'s witness. The caller keeps the opaque metadata in a per-image cache variable (`$s3App9makeShapeQryFQOyQo_Md`, "demangling cache variable"), filled once by `swift_getTypeByMangledNameInContext2` (seen in the `-emit-ir` output). The conformance comes from the replaceable descriptor accessor `...QOMg`, which returns the new type. Old metadata combined with a new conformance is undefined behavior.
  - With `AnyView` the concrete type never changes.
- **UIKit.** `ViewControllerHost` and `ViewHost` create the hosted view controller or view again from an `@autoclosure` on each injection ([IJ Hosts.swift L22-68](https://github.com/krzysztofzablocki/Inject/blob/67e3ee9a2b/Sources/Inject/Integrations/Hosts.swift#L22-L68)). The other option is `@objc func injected()` ([I3 README L66-84](https://github.com/johnno1962/InjectionIII/blob/f793d95f6b/README.md#L66-L84)).
- **Compiler-generated erasure in Xcode 27.2.**
  - SwiftUICore declares `@_typeEraser(DebugReplaceableView) @_typeEraser(AnyView) public protocol View`. `DebugReplaceableView` is iOS 26+ (local `SwiftUICore.swiftmodule/arm64-apple-ios-simulator.swiftinterface` L17788, L6700-6713).
  - The type checker wraps a `return` of an opaque type in the protocol's type eraser when the function is `dynamic`, or when `OpaqueTypeErasure` is on ([SW ConstraintSystem.cpp L4679-4691](https://github.com/swiftlang/swift/blob/03902ae424/lib/Sema/ConstraintSystem.cpp#L4679-L4691)).
  - I emitted SILGen for a one-line `ContentView` **[ran]**. With `-enable-implicit-dynamic` it calls `DebugReplaceableView.init(erasing:)` and has two dynamically replaceable functions. Without the flag there is no eraser call.
  - Xcode's `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE` maps to `-enable-experimental-feature OpaqueTypeErasure`. Its default is `NO`, with the comment "rdar://143344956 (Disable opaque type erasure for debug builds)" (local `SWBUniversalPlatform.framework/.../Swift.xcspec` L1554-1565).
  - HotSwiftUI's comment ".enableInjection() optional with Xcode 16+" ([HS L25](https://github.com/johnno1962/HotSwiftUI/blob/868e889cf8/Sources/HotSwiftUI/HotSwiftUI.swift#L25)) is probably out of date for 27.2, because that default is now `NO` **[inferred]**.

### 3. `@_dynamicReplacement(for:)` and `-enable-implicit-dynamic`

- **Definition.** The replacement happens "at program start (or loading a shared library)" ([SW UnderscoredAttributes.md L123-131](https://github.com/swiftlang/swift/blob/03902ae424/docs/ReferenceGuides/UnderscoredAttributes.md#L123-L131)). The hidden frontend flags are `-enable-implicit-dynamic` ("Add 'dynamic' to all declarations") and `-enable-dynamic-replacement-chaining` ([SW FrontendOptions.td L898-900, L945-948](https://github.com/swiftlang/swift/blob/03902ae424/include/swift/Option/FrontendOptions.td#L898-L948)). `-enable-private-imports` allows `@_private(sourceFile:)` imports ([SW Options.td L1771-1773](https://github.com/swiftlang/swift/blob/03902ae424/include/swift/Option/Options.td#L1771-L1773)).
- **Code generation.**
  - Each dynamic function gets a prologue. It loads the chain root's `implementationFunction` and calls `swift_getFunctionReplacement` ([SW GenDecl.cpp L3243-3310](https://github.com/swiftlang/swift/blob/03902ae424/lib/IRGen/GenDecl.cpp#L3243-L3310), [FunctionReplacement.cpp L19-35](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/FunctionReplacement.cpp#L19-L35)). If the pointer is the function itself, the function runs its own body. If not, it tail-calls the replacement.
  - The chain root is the symbol `...TX` ("dynamically replaceable variable") in `__DATA,__data`. The key is `...Tx` in `__TEXT,__const` (`nm -m` and `swift-demangle`) **[ran]**.
  - The SIL instructions are `dynamic_function_ref` and `prev_dynamic_function_ref` ([SW Instructions.md L2317-2391](https://github.com/swiftlang/swift/blob/03902ae424/docs/SIL/Instructions.md#L2317-L2391)).
- **Runtime.**
  - The Swift runtime registers an add-image callback through `objc_addLoadImageFunc2` or `_dyld_register_func_for_add_image` ([SW ImageInspectionMachO.cpp L236-248, L277-284](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/ImageInspectionMachO.cpp#L236-L284)).
  - For each image it reads `__TEXT,__swift5_replace` and `__TEXT,__swift5_replac2` ([ImageInspectionCommon.h L38-39](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/ImageInspectionCommon.h#L38-L39), [ImageInspectionCommon.cpp L71-83](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/ImageInspectionCommon.cpp#L71-L83)). It enables each replacement under a lock ([MetadataLookup.cpp L4155-4210](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/MetadataLookup.cpp#L4155-L4210)).
  - `enableReplacement` links the new entry at the chain root. Without chaining, it first unlinks the previous replacement, so the newest dylib wins ([L3992-4043](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/MetadataLookup.cpp#L3992-L4043)).
  - `__swift5_replac2` maps old opaque type descriptors to new ones ([L4111-4125](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/MetadataLookup.cpp#L4111-L4125)). Only lookups through `_findOpaqueTypeDescriptor` read that map ([L1874-1890](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/MetadataLookup.cpp#L1874-L1890)).
- **Can a dylib loaded later replace functions in the main app? Yes [ran].**
  - Setup: the app was built with `-enable-implicit-dynamic -enable-private-imports`. The patch dylibs used `@_private(sourceFile: "Types.swift") import App` and `@_dynamicReplacement(for:)`.
  - In an iOS 27.2 simulator process, the patches replaced a struct method, a final class method, a non-final class method, and a computed global.
  - A second dylib replaced the first (v2 then v3).
  - No `-interposable`, fishhook, or vtable patch was needed.
  - The first `dlopen` took about 260 ms (cold). Later runs took 0.5-1.6 ms.
- **Limits.**
  - Implicit dynamic is not applied to `@inlinable`, `@_transparent`, `@_silgen_name`, `@_cdecl`, or `@extern` declarations. It also skips defer bodies, local functions, stored properties without observers, and local or implicit variables ([SW TypeCheckAttr.cpp L6844-6911](https://github.com/swiftlang/swift/blob/03902ae424/lib/Sema/TypeCheckAttr.cpp#L6844-L6911)).
  - Only bodies are replaced. You cannot add stored properties, change layout, or add vtable entries **[inferred: the chain holds only function pointers]**.
  - Changing an opaque result type is safe only before its first use (see section 2) **[ran]**.
  - There is no unload. A runtime comment says a duplicate-enable check stays disabled "until we make sure that when a dynamic library is unloaded all descriptors are removed" ([L4001-4009](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/MetadataLookup.cpp#L4001-L4009)).
  - The patch source must name each original declaration. A tool therefore has to generate one `@_dynamicReplacement(for:)` function for each changed function **[inferred]**.
  - The patch needs the app's `.swiftmodule` and the same compiler flags **[inferred]**.
- **Cost [ran].** Benchmark: 100M iterations, each calling two small functions, in an iOS 27.2 simulator process.

  | Optimization | Without implicit dynamic | With implicit dynamic |
  |---|---|---|
  | `-Onone` | 69.9 ns/iter | 74.7 ns/iter (+7%) |
  | `-O` | 0.78 ns/iter | 3.08 ns/iter (inlining blocked) |

  Each dynamic function also adds one `TX`/`Tx` symbol pair.

### 4. Simulator specifics

All results in this section are **[ran]**. I used a throwaway device in a private device set (`xcrun simctl --set <scratchpad>/simset create ...`) and ran binaries with `xcrun simctl spawn -s`, which needs no booted device. I deleted the device afterwards. I did not boot or change any of the user's simulators.

- **Code signing.**
  - An unsigned dylib fails `dlopen` with "code signature in <...> not valid for use in process: Trying to load an unsigned library". dyld builds this error from its `F_CHECK_LV` check ([DY Loader.cpp L1621-1643](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/dyld/Loader.cpp#L1621-L1643)).
  - An ad-hoc signature with one byte changed in `__text` gets the process killed with SIGKILL.
  - The linker's ad-hoc signature loads. No Team ID is needed.
  - Xcode-built Debug-iphonesimulator apps on this machine are ad-hoc signed, with `TeamIdentifier=not set` and no hardened-runtime flag (`codesign -dv`). So no library validation applies **[inferred from the flags]**.
- **Platform.** A macOS dylib is rejected with "incompatible platform (have 'macOS', need 'iOS-simulator')" ([DY MachOFile.cpp L1815](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/common/MachOFile.cpp#L1815)). Build patches with `-target arm64-apple-ios27.2-simulator`. `vtool -show-build` shows `platform IOSSIMULATOR`.
- **Host paths.** A simulator process opened `/private/tmp/.../plugin_sim.dylib` with `dlopen`. dyld_sim first tries `$SIMULATOR_ROOT/<path>` and then the host path; the error text lists both. In a spawned process, `HOME` is the device's data directory.
- **`SIMCTL_CHILD_` environment variables.**
  - `simctl help launch` and `simctl help spawn` both document the prefix.
  - With `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/host/.../insert_sim.dylib`, the inserted dylib's constructor ran before `main`, and the child saw `DYLD_INSERT_LIBRARIES`.
  - A plain `DYLD_INSERT_LIBRARIES` set for simctl did not reach the child.
  - dyld reads the variable in [DY DyldProcessConfig.cpp L2081](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/dyld/DyldProcessConfig.cpp#L2081). It rejects `@loader_path` and does not expand `@rpath` in inserted paths ([Loader.cpp L1277-1280, L1363](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/dyld/Loader.cpp#L1277-L1363)).
  - I did not test `simctl launch`, because it needs a booted device and an installed app.
- **`simctl spawn -s`** (marked deprecated) runs a simulator binary without booting. It is useful for loader tests.
- **LLDB.** `lldb -p <pid> -o "process load <host path>"` loaded a dylib into the simulator process and the dylib's constructor ran. Attach, load, and detach took 0.48 s together. It worked with Developer Mode disabled, for this non-hardened process.
- **JIT memory.** In the simulator process, three methods ran generated arm64 code (`mov w0,#42; ret` returned 42):
  - MAP_JIT RWX plus `pthread_jit_write_protect_np`. The SDK marks this function unavailable on iOS (`pthread.h` L586-588), so I called it through `dlsym`.
  - Plain RW memory, then `mprotect` to RX.
  - A `vm_remap` dual mapping.

### 5. Ambitious ideas

#### 5.1 Relinking the whole app module into a fresh dylib

- **Possible:** linking all app code into a dylib and loading it. Xcode already builds Debug app code as `<App>.debug.dylib`, which a stub executable loads through `@rpath` (`otool -L` on a local simulator app) **[ran]**.
- **Blocks:**
  - The new dylib defines a second copy of every type. ObjC warns "implemented in both" **[ran]**.
  - The Swift conformance cache keeps the first conformance it finds ([SW ProtocolConformance.cpp L1055-1066](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/ProtocolConformance.cpp#L1055-L1066)).
  - Live objects keep the old metadata, and globals get new storage.
  - Old code still calls old symbols, so the tool would still need the section 1.4 rebinding, for more symbols.
  - dyld never unloads images that contain Swift or ObjC ([DY MachOAnalyzer.cpp L2829-2838](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/common/MachOAnalyzer.cpp#L2829-L2838)).
- **Verdict:** this gives no benefit over a one-file dylib.
- **Variation to test:** link patches against `<App>.debug.dylib` (two-level namespace) instead of the deprecated `-undefined dynamic_lookup` **[inferred, not tested]**.

#### 5.2 Patching type metadata or witness tables at runtime

- **Class vtables:** this works. InjectionLite does it, and my one-slot patch worked **[ran]**. Swift class metadata here is in writable `__DATA` **[ran: the write did not fault]**.
- **Witness tables:** not needed for body changes. Witness thunks call through the stub, so GOT rebinding covers protocol and generic dispatch **[ran]**. Writes to `__DATA_CONST` need `vm_protect(VM_PROT_COPY)` on iOS 27 ([FH fishhook.c L111-128](https://github.com/johnno1962/fishhook/blob/adc337e921/fishhook.c#L111-L128)).
- **Layout (size, stride, field offsets):** this cannot be patched, because live instances already use the old layout. InjectionLite only detects the change ([IL Reloader.swift L117-160](https://github.com/johnno1962/InjectionLite/blob/a74f69ece8/Sources/InjectionImpl/Reloader.swift#L117-L160)).

#### 5.3 LLVM ORC JIT in the simulator process

- **OS:** nothing blocks it for an ad-hoc, non-hardened simulator process. Three allocation methods worked (section 4) **[ran]**.
- **Toolchain:**
  - Swift has an in-process ORC `LLJIT` for `swift -interpret` ([SW SwiftMaterializationUnit.cpp L13-14, L30](https://github.com/swiftlang/swift/blob/03902ae424/lib/Immediate/SwiftMaterializationUnit.cpp#L13-L30)).
  - No LLVM or Swift-frontend library for the iOS-simulator platform ships with Xcode, so it would have to be built **[inferred]**.
  - Out-of-process option: LLVM's `SimpleRemoteEPC` keeps the JIT linker on the host and runs a small executor in the target ([LL SimpleRemoteEPC.h L9, L30](https://github.com/llvm/llvm-project/blob/aab5b20337/llvm/include/llvm/ExecutionEngine/Orc/SimpleRemoteEPC.h#L9-L30), [llvm-jitlink-executor.cpp L9, L77-94](https://github.com/llvm/llvm-project/blob/aab5b20337/llvm/tools/llvm-jitlink/llvm-jitlink-executor/llvm-jitlink-executor.cpp#L9-L94)).
- **Gain:** it replaces only the link step and `dlopen`, about 60 ms plus 1 ms measured. Existing callers still need GOT, vtable, or dynamic-replacement redirection.
- **Extra work:** Swift registers metadata sections (conformances, replacements) through dyld add-image callbacks ([SW ImageInspectionMachO.cpp L236-248](https://github.com/swiftlang/swift/blob/03902ae424/stdlib/public/runtime/ImageInspectionMachO.cpp#L236-L248)). JIT code bypasses dyld, so the tool would have to register these sections itself **[inferred; I did not check ORC's MachOPlatform]**.
- **Verdict:** low gain for a large build effort.

#### 5.4 LLDB `process load` and `expr`

- **Status:** `process load` works on a simulator process **[ran]**.
- **Blocks:**
  - Only one debugger can attach. When the app runs from Xcode with debugging on, a second attach should fail **[inferred, not tested]**.
  - Each attach pauses the app for about 0.5 s.
  - `expr` compiles with LLDB's built-in Swift compiler, not the project's exact flags **[inferred]**.
- **Use:** a fallback that loads the injection client into an app that does not link it.

#### 5.5 dyld interposing

- `dyld_priv.h` calls static interposing through `DYLD_INSERT_LIBRARIES` the safer way. It warns that dynamic interposing misses pointers the program has already copied ([DY dyld_priv.h L440-451](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/include/mach-o/dyld_priv.h#L440-L451)).
- `dyld_dynamic_interpose` is a no-op ([libdyldGlue.cpp L555-560](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52/libdyld/libdyldGlue.cpp#L555-L560)).
- Static interposing therefore applies only at launch **[inferred]**.

### Mechanism table

| Mechanism | What it can replace | What it cannot replace | Maturity (Nov 2026) |
|---|---|---|---|
| fishhook GOT rebinding after `dlopen` (app linked with `-interposable` and `-enable-testing`) | Bodies of exported functions. Struct, enum, and final-class methods. Static methods, getters, setters. Protocol and generic calls through thunks. | `private`/`fileprivate` symbols, non-final class methods (they need a vtable patch), stored layout, signatures, inlined code | In daily use in InjectionNext/InjectionLite. iOS 27 `vm_protect` fix shipped Oct 2026. Verified in the 27.2 simulator. |
| Swift vtable slot patch | Non-final class methods | Added, removed, or reordered methods; layout | In daily use (InjectionLite). Verified. |
| ObjC `class_replaceMethod` | `@objc` methods | Layout | Old and stable API. |
| `swift_allocateGenericClassMetadata` hook | Vtables of generic class specializations | Layout | InjectionLite (Generics.swift, July 2025). |
| `@_dynamicReplacement` with `-enable-implicit-dynamic` | Every non-inlinable function, method, or computed property. Includes non-final class methods, and private ones with private imports. | Stored layout, opaque result type after first use, signatures, unload | Underscored compiler feature. Verified from a later `dlopen`. +7% call cost at `-Onone`. |
| Type erasure (`AnyView` / `DebugReplaceableView`) | Changes of the concrete `body` type | Not applicable | Manual (Inject, HotSwiftUI) or automatic with implicit dynamic (verified in SILGen). |
| `@ObserveInjection` plus notification | Triggers re-render of the observing views | Views without the property | Inject 1.6.0, HotSwiftUI 1.2.5. |
| `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` | Loads a client dylib at launch | Code already running | dyld feature. Verified with `spawn`. |
| LLDB `process load` | Loads a dylib into a running process | Apps that already have a debugger attached (inferred) | Verified. |
| In-process or remote ORC JIT | Generates code without dlopen | Still needs redirection; Swift runtime section registration | Not built. OS allows the memory. |
| `dyld_dynamic_interpose` | Nothing | Everything | No-op in dyld-1378. |
| Whole-module relink | Nothing beyond one-file injection | Types and state get duplicated | Not useful. |

### Open questions

1. If Xcode already debugs the app, does a second LLDB attach fail? I did not test it.
2. Can a patch dylib link against `<App>.debug.dylib` with a two-level namespace, and so avoid the deprecated `-undefined dynamic_lookup`? I did not test it.
3. When an agent edits a file that Xcode never opened, InjectionNext waits for the SourceKit arguments ([NextCompiler.swift L268-271](https://github.com/johnno1962/InjectionNext/blob/b39c9f15cf/App/InjectionNext/NextCompiler.swift#L268-L271)). The log path with `EMIT_FRONTEND_COMMAND_LINES` avoids this. Which source of compile commands is reliable for an agent with no Xcode GUI? An option is to capture commands from `xcodebuild` with that setting.
4. With `-enable-implicit-dynamic`, does SwiftUI keep view state when a `DebugReplaceableView` body changes its inner type? This overlaps with the Previews research.
5. Does SwiftUI's attribute graph cache view types the way the caller cache did in my opaque-type test, even with `AnyView`? I did not test it.
6. I did not run `simctl launch` with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` on a booted device with an Xcode-built app.
7. I did not capture the kernel's reason for the SIGKILL on the corrupted signature. `log show` returned nothing.
8. Can the tool combine both mechanisms: implicit dynamic for normal edits, and fishhook as a fallback for symbols that dynamic replacement does not cover? I did not test it.

### Appendix: local experiments

All artifacts are in `/private/tmp/claude-501/-Users-tgomareli-Development-hotreloading/f6546c1e-2418-4397-b695-4946d893591b/scratchpad/a-work/exp/`. Source clones are in `../src/`.

- `c/`: C test binaries.
  - Build: `xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.2-simulator -dynamiclib plugin.c -o plugin_sim.dylib`. The host is built the same way from `host.c`.
  - Variants: unsigned (`codesign --remove-signature`), one byte changed in `__text`, and macOS-platform.
  - Run: `xcrun simctl --set simset spawn -s <udid> c/host_sim <dylibs...>`, with and without `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`.
  - JIT probe: `c/jit_sim {mapjit|mprotect|remap}`.
  - LLDB: `c/waiter_sim` plus `xcrun lldb -b -p <pid> -o "process load c/plugin_sim.dylib" -o detach`.
- `dr/`: dynamic replacement.
  - App: `swiftc -target arm64-apple-ios27.2-simulator -Onone -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports Types.swift main.swift`.
  - Patches: `swiftc -emit-library Patch2.swift -I out -Xlinker -undefined -Xlinker dynamic_lookup`.
  - The `SIMCTL_CHILD_SKIP_START=1` run shows the opaque-type case with the patch loaded before first use.
  - IR evidence: `dr/ir/main.ll`.
- `interp/`: `otool -Iv` comparison of plain, `-interposable`, `-enable-testing`, and both together.
- `fh/`: fishhook end-to-end test (`App`, `App_noninterposable`, `patch_v2.dylib`) and the timing of `swift-frontend -c` plus `clang` link.
- `erase/`: SILGen of a SwiftUI view: plain, implicit dynamic, and `OpaqueTypeErasure`.
- `bench/`: implicit-dynamic overhead (`b_{Onone,O}_{plain,dyn}`).
- The simulator device set `simset/` was created for these tests and deleted after (`simctl --set ... delete`).

---

## Part B: Apple's own hot reload (Previews, debug dylib, LLDB, rea)

Environment: macOS 27.2 (26B123), Xcode 27.2 (27B52), arm64 (`uname -m`).
Date: 2026-11-21.

Path shorthands used below:

- `$XC` = `/Applications/Xcode.app/Contents`
- `$RR` = `/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.2.8117.0.3WAg72/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.2.simruntime/Contents/Resources/RuntimeRoot` (iOS 27.2 sim runtime, from `xcrun simctl list runtimes -j`)
- `$W` = the `b-work/` directory next to this file. Raw `strings`/`nm` dumps are in `$W/strings/`.

Labels: **verified** means I ran the command or read the source. **inferred** means I concluded it from strings, symbol names or design, without running it.

### Short answer

Since Xcode 16, Previews runs your real app binary. Xcode builds a tiny stub executable plus `<App>.debug.dylib`. In preview mode it injects `PreviewsInjection.framework` into the app, prevents dyld from loading the debug dylib, and JIT-links your object files into the process with **XOJIT** (an ORC-based JIT). When you edit a file, Xcode recompiles only that file as a "thunk" object. `PreviewShell` (in the simulator) then swaps it in through `XOJIT.ReplacementManager`. Literal-only edits skip the compile and update values through `__designTimeString` and similar functions.

All of this is private and runs only inside the Previews launch path. You cannot attach it to an app that was started with Run. Two public pieces are reusable now. First, Swift dynamic replacement plus `dlopen` through LLDB: I measured 0.03 to 0.44 s per load on a macOS process. Second, the debug-dylib split, which exports internal symbols.

---

### Q1. `ENABLE_DEBUG_DYLIB`

#### What it is

- Apple's description: "If enabled, debug builds of app and app extension targets on supported platforms and SDKs will be built with the main binary code in a separate "NAME.debug.dylib". A stub executor that loads the dylib will be the main binary. Enabling this setting is required for the previews execution engine and other modern development features to work." Sources: https://developer.apple.com/documentation/xcode/build-settings-reference (section "Enable Debug Dylib Support") and the same text in `$XC/SharedFrameworks/SwiftBuild.framework/.../SWBCore.framework/Versions/A/Resources/CoreBuildSystem.xcspec`, line 3833. **Verified.**
- The default is `ENABLE_DEBUG_DYLIB = YES` for the Application and App Extension product types and `NO` for others, such as the Messages stub types. Source: `DarwinProductTypes.xcspec` lines 40, 262, 299 (`grep -n ENABLE_DEBUG_DYLIB`). **Verified.**
- WWDC24 "What's new in Xcode 16" says Previews "uses the same build products for your project and reassembles your program on the fly, no longer needing to produce a separate copy." https://developer.apple.com/videos/play/wwdc2024/10135/ **Verified.**
- Release notes only list workarounds:
  - Xcode 16.3 fixed an `LD_CLIENT_NAME` crash where the debug dylib was not found.
  - Xcode 16.3 says `-stack_size` needs `ENABLE_DEBUG_DYLIB=NO`.
  - Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-16_3-release-notes **Verified.**

#### What the build produces

Source: `swiftlang/swift-build`, which is the open-source build engine Xcode uses.

- `Sources/SWBCore/Settings/Settings.swift` (`addPreviewsOverrides`, about lines 3660–3830; `previewStyle`, about line 6295): https://github.com/swiftlang/swift-build/blob/main/Sources/SWBCore/Settings/Settings.swift
  - `EXECUTABLE_DEBUG_DYLIB_PATH` = `$(EXECUTABLE_PATH:dir)$(EXECUTABLE_NAME).debug.dylib`.
  - `EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME` = `@rpath/$(EXECUTABLE_NAME).debug.dylib`.
  - `EXECUTABLE_BLANK_INJECTION_DYLIB_PATH` = `$(EXECUTABLE_PATH:dir)__preview.dylib`.
  - These three are set only when the preview style is `.xojit` and the target is `mh_execute` on iphoneos/simulator, tvOS, watchOS, visionOS or macOS.
  - `previewStyle` is `.dynamicReplacement` when `ENABLE_PREVIEWS=YES` and `.xojit` when `ENABLE_XOJIT_PREVIEWS=YES`.
- `Sources/SWBTaskConstruction/TaskProducers/BuildPhaseTaskProducers/SourcesTaskProducer.swift` (about lines 1300–1470): https://github.com/swiftlang/swift-build/blob/main/Sources/SWBTaskConstruction/TaskProducers/BuildPhaseTaskProducers/SourcesTaskProducer.swift
  - The stub links `$PLATFORM/Developer/usr/lib/libPreviewsJITStubExecutor.a`, or the `_no_swift_entry_point` variant.
  - The linker adds three `__TEXT` sections: `__debug_dylib` (relative path), `__debug_entry` (original `LD_ENTRY_POINT`) and `__debug_instlnm` (install name).
  - Comment in the source: "rdar://127248825 (Pre-link the debug dylib and emit a new empty dylib that Previews can load to get in front of dyld) ... construct the empty stub dylib with the same install name so Previews can leverage dyld behavior to block loading the original debug dylib until it is ready."

I checked a real Xcode 27.2 build on this Mac (SDK 27.2, `otool -l | grep -A5 LC_BUILD_VERSION`). The path is `~/Library/Developer/Xcode/DerivedData/Gallery-*/Build/Products/Debug-iphonesimulator/Gallery.app`. **Verified.**

| File | Size | Facts (command) |
|---|---|---|
| `Gallery` (stub) | 40 KB | `otool -L`: `@rpath/Gallery.debug.dylib`, libSystem only. Exports `___debug_blank_executor_main`, `___previews_blank_executor_run_user_entry_point` (`nm -gU`). |
| `Gallery.debug.dylib` | 926 KB | `MH_DYLIB`, install name `@rpath/Gallery.debug.dylib`. Exports 208 symbols, including internal `RootView.body.getter` and `GalleryApp.$main()` (`nm -gU \| swift demangle`). Has 0 "dynamically replaceable" symbols and no `__swift5_replace` section. |
| `__preview.dylib` | 16 KB | `MH_DYLIB` with the same install name, `@rpath/Gallery.debug.dylib` (`otool -D`). This is the blank decoy. |

The stub's run-time logic is in `strings $XC/Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib/libPreviewsJITStubExecutor.a`. **Verified** strings; the order is **inferred**:

1. If `__PREVIEWS_JIT_LINK` is set, the stub looks up `__previews_injection_jit_link_entrypoint` ("Looking for Previews JIT link entry point.") and gives control to PreviewsInjection.
2. If `__PREVIEWS_INTERPOSED_DEBUG_DLIB` is set, it expects a pseudodylib ("Debug dylib is interposed. Looking for entry trampoline in pseudodylib.").
3. Otherwise it opens the real debug dylib and calls `__debug_main_executable_dylib_entry_point`.

#### Can a third-party tool reuse the split?

- Not for swapping code. In a normal Run, dyld loads `<App>.debug.dylib` once. Swift images cannot be unloaded safely, so you cannot swap the whole dylib (**inferred** from Swift runtime design, not tested).
- The split does help in two ways:
  - Internal Swift symbols are exported from the debug dylib (**verified** above). A patch dylib can bind to app internals with `-undefined dynamic_lookup`.
  - The `__preview.dylib` trick shows how to stop dyld from loading the real code. A tool could insert its own decoy and load the app code itself, for example through a JIT. This is exactly what Previews does. It is **inferred** that we could copy it, and I did not test it.
- One limit: calls inside the debug dylib are direct branches, so dyld interposing cannot redirect them (**inferred**, standard dyld behavior).

---

### Q2. Previews pipeline (Xcode 16 to 27)

#### Components located

| Side | Binary | Role (evidence) |
|---|---|---|
| Xcode (host) | `$XC/SharedFrameworks/PreviewsPipeline.framework` | Change detection, thunk builds, update plans. Strings: "Changes localized to hot swappable functions, can just rebuild thunks and hot swap", "Changes localized to functions, can just rebuild thunks, not hot swap", `buildThunk(hotSwap)`, `buildThunk(relaunch)`, "update invalidates cold swap content", "Can't do incremental update: Code changed beyond literals from last update", `LiteralChangeDetector`, `RunningAppPreviewManager`. |
| Xcode | `$XC/PlugIns/PreviewsXcode.framework` | Writes thunk source. Strings: `__XCPREVIEW_THUNKSUFFIX__.preview-thunk.`, `import func SwiftUI.__designTimeSelection`. It checks `ENABLE_DEBUG_DYLIB` and reports JIT directory errors ("ls -ld /private/var/OOPJit \"$TMPDIR/OOPJit\""). |
| Xcode | `$XC/SharedFrameworks/PreviewsPlatforms.framework` | Installs and launches the app ("agent"). Strings: `launchAgentApp(...additionalEnvironment:...)`, `DYLD_INSERT_LIBRARIES`, `__PREVIEWS_INTERPOSED_DEBUG_DLIB`, `__PREVIEWS_EXECUTABLE_DYLIB_NAME`, `@executable_path/__preview.dylib`, `UVBlockDebugDylibLoading`, `UVLogLaunchEnvironment`. |
| Xcode | `$XC/SharedFrameworks/PreviewsDeveloperTools.framework` | Sim transport. Strings: `com.apple.dt.previewsd.{previewservice,agentpipeservice,shellpipeservice}.host-to-sim`, "Establishing connection to %@ using host-to-sim connection", `SimDevice` `lookup:error:`, `LaunchPreviewShellSim`. |
| Build service | SWBCore (swift-build) | `generatePreviewInfo` returns the exact frontend command line used to compile one thunk (details below). |
| Sim runtime | `$RR/System/Library/PrivateFrameworks/PreviewsOSSupport.framework/Support/previewsd` | launchd daemon `com.apple.dt.previewsd`, with Mach services `*.previewservice[.host-to-sim]`, `*.agentpipeservice[...]`, `*.shellpipeservice[...]`, `installservice`, `crashlistener` and `processexit` (`plutil -p $RR/System/Library/LaunchDaemons/com.apple.dt.previewsd.plist`). |
| Sim runtime | `$RR/Applications/PreviewShell.app` + `PreviewShellKit.framework` | FrontBoard host for preview scenes and the JIT linker. Entitlement `com.apple.private.oop-jit.loader = previews` (embedded `__TEXT,__entitlements`, decoded with `b-work/scripts/ents.py`). Classes: `PreviewsJITLinker`, `PreviewReloader`, `XOJITAgentSymbolTableDataProvider`. Strings: "Loading %s, identifier %s, forReplacement: %{bool}d", "Found %ld XOJIT loadable products", "Loading static archive %s into XOJIT". Links `XOJIT.framework` (`otool -L`). |
| Sim runtime | `$RR/.../PrivateFrameworks/XOJIT.framework` (13 MB, `PROJECT:xojit-84`) | An LLVM ORC JIT with a Swift API. Exports (`nm -m \| swift demangle`): `XOJIT.init(fromXPCConnection:oopJITLinkageType:opaqueOwner:)`, `XOJIT.init()`, `loadLinkableFile(path:archives:identifier:)`, `ObjectLinkingLayer.add(object:to:)`, `ReplacementManager.addWithReplacement(object:to:)`, `ReplacementManager.applyPendingUpdates(to:)`, `runProgramOnMainThread(symbol:jitDylibName:arguments:)`, `setLoadableAtPathViaRegex(jd:regex:replacement:)`. It contains the ORC `MachOPlatformRuntimeState` and the `_dyld_pseudodylib_*` callbacks. |
| App process | `$RR/.../PrivateFrameworks/XOJITExecutor.framework` | ORC executor over XPC. Strings: `__llvm_orc_SimpleRemoteEPC_dispatch_fn`, `__xojit_xpcmemmgr_acquire_slab`, `UseOOPJIT`, `IsSandboxed`, "failed to map code file". Swift API: `XOJITExecutor.init(connection:)`, `start(terminationHandler:)`, `handleRunProgramOnMainThread()`. |
| App process | `$RR/.../PrivateFrameworks/PreviewsInjection.framework` | Inserted into the app. Exports `__previews_injection_jit_link_entrypoint` and `__previewsInjectionJITLinkEntrypoint(argc:argv:previewsDylibPath:previewsDylibEntryPointName:)`. Contains `JITBootstrapAgent`, `JITLinkWaiter`, `UVBSEndpointMonitor` and the entry points `PreviewEntryPoint`, `MainPreviewEntryPoint`, `RunningAppEntryPoint`, `RegistryEntryPoint` (rea output, Q3). Weak-links `XOJITExecutor`. String: `__PREVIEWS_CLEAR_MODIFIER_CACHE_AFTER_HOT_SWAP`. |
| Framework targets | `$XC/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app` | A generic host used when no app stub exists ("No debug dylib present, assuming framework agent"). Contains only the Swift types `ContentView` and `FrameworkAgentApp` (rea). Entitlement: `get-task-allow` only. |
| SDK | `DeveloperToolsSupport.swiftinterface` (iOS sim SDK 27.2) | Public: `__designTimeString/Integer/Float/Boolean(_ key: String, fallback: T) -> T` and `__designTimeApplyIncrementalValues(_ updates: [[String: any Sendable]])`. |

#### How an edit reaches the running preview

Steps 1 and 3 are **verified**. Steps 2, 4, 5, 6 and 7 are **inferred** from strings and symbols.

1. **Launch.**
   - Xcode installs the real app into a Previews-only simulator device set (`~/Library/Developer/Xcode/UserData/Previews/Simulator Devices`).
   - It launches the app with `DYLD_INSERT_LIBRARIES` (PreviewsInjection, plus `@executable_path/__preview.dylib` as the decoy), `__PREVIEWS_JIT_LINK`, `JIT_BOOTSTRAP_AGENT_CONNECTION_IDENTIFIER`, `__PREVIEWS_INTERPOSED_DEBUG_DLIB` and `__PREVIEWS_EXECUTABLE_DYLIB_NAME`.
   - Evidence: these strings sit together in PreviewsPlatforms and PreviewShellKit (`grep -lF` over `$W/strings`). The exact env pairing is **inferred**.
2. **First JIT link.**
   - The stub calls `__previews_injection_jit_link_entrypoint`.
   - PreviewsInjection connects to PreviewShell's BoardServices service `com.apple.uv.agent-jit-bootstrap-service` (listed in `PreviewShell.app/Info.plist` `BSServiceDomains`). It then starts `XOJITExecutor`.
   - PreviewShell's `PreviewsJITLinker` loads the app's object files and archives into XOJIT ("InitialJITLink").
   - XOJIT registers the JIT code with dyld as a pseudodylib named `@rpath/<App>.debug.dylib`. Evidence: `_dyld_pseudodylib_register` in XOJIT, and the build-service comment about constructing the pseudodylib from the install name.
3. **Thunk source.**
   - Xcode writes `<file>.__XCPREVIEW_THUNKSUFFIX__.preview-thunk.swift`.
   - Literals become `__designTimeString("<key>", fallback: ...)` and similar calls (the `__designTime*(` strings are in PreviewsPipeline).
4. **Compile (verified in source).**
   - SWBBuildService `generatePreviewInfo` takes the original file's frontend command and strips sidecar outputs.
   - In XOJIT mode it keeps the same module and flags ("we want XOJIT mode to invoke builds as close as possible to the original"). It also passes the other module sources and maps the thunk as the primary input through a new `-output-file-map`.
   - Output: one relocatable `.o`.
   - Source: `Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift`, about lines 3560–3830, https://github.com/swiftlang/swift-build/blob/main/Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift
5. **Transport.**
   - Xcode reaches the simulator with CoreSimulator `SimDevice lookup:` on `com.apple.dt.previewsd.*.host-to-sim`.
   - previewsd and PreviewShell expose message pipes (`com.apple.uv.pipe-service` in the domains `host-agent-pipe`, `host-shell-pipe` and `shell-agent-pipe`).
   - Payloads are property lists with `Ultraviolet.*` type names: `Ultraviolet.PreviewProvider`, `Ultraviolet.RegistryExecution`, `Ultraviolet.RunningAppPreview`, `Ultraviolet.ApplicationMainPreview`, and others (`strings PreviewsMessagingOS`). rea found `EntryPoint.decode(updatePayload: PropertyList)`.
6. **Hot swap.**
   - PreviewShell links the new `.o` "for replacement" (`loadingReplacementObjectFile`, "relocatable object (for replacement)").
   - It does this through `XOJIT.ReplacementManager.addWithReplacement` and `applyPendingUpdates`. XOJIT has ORC stub-redirect strings ("error resolving implementation for stub %p").
7. **Refresh.**
   - PreviewsInjection gets an update message (`UpdateContext`, `SceneServices`) and re-renders. It clears SwiftUI's modifier cache unless `__PREVIEWS_CLEAR_MODIFIER_CACHE_AFTER_HOT_SWAP` says not to ("Will clear modifier cache after hot swap").
   - Literal-only edits skip steps 3–6. Xcode sends new values (`applyIncrementalUpdates`, `literalValueByPath`), and the agent applies them with `__designTimeApplyIncrementalValues`.

#### Legacy mode (still present)

- `PreviewStyle.dynamicReplacement` compiles the app with `-Xfrontend -enable-implicit-dynamic -enable-private-imports -enable-dynamic-replacement-chaining -disable-previous-implementation-calls-in-dynamic-replacements`.
- Thunks are built as a separate module, `<Module>_PreviewReplacement_<file>_<suffix>`, using `@_dynamicReplacement(for:)`.
- Source: `SwiftCompiler.swift`, about lines 2028–2036 and 3756–3770. **Verified.**
- Release notes name it "Legacy Previews Execution": https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes **Verified.**

#### SwiftUI opaque types

- Xcode 16.2: debug builds wrapped `some View` in `AnyView` "to allow SwiftUI Previews to dynamically replace the implementation of methods like body". Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-16_2-release-notes
- Xcode 16.3: this is off by default, and Previews "recompiles the edited file with this setting only when running a preview". Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-16_3-release-notes
- The setting `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES` maps to `-enable-experimental-feature OpaqueTypeErasure` (`Swift.xcspec`, line 1554). **Verified.**

---

### Q3. rea (https://github.com/morluto/rea)

- **What it is.** An MIT-licensed TypeScript MCP server and CLI. The npm package is `rea-agents` 6.10.1 and the command is `rea`.
  - Decompiling and xrefs need an external engine: Hopper, Ghidra 12.2 or later, IDA or Kuna.
  - Some commands read Mach-O directly and need no engine: `inspect-native-dispatch-metadata` (ObjC classes and protocols, Swift types, conformances, vtables), `inspect-macho`, `trace-dylib-resolution`, `inspect-native-initializers` and `demangle-swift`.
  - `observe-native-calls` launches a new macOS process under LLDB. It cannot attach to a simulator process.
  - Docs read: the README, `docs/getting-started/cli.md`, `installation.md`, `docs/guides/native/native-investigation.md`, `docs/guides/apple/apple-application-analysis.md` and `package.json`. Copies are in `$W/rea-docs/`. I did not read all the source; the repo is 199 MB.
- **Install (succeeded).**
  - Command: `npm install --prefix $W/rea/pkg --ignore-scripts rea-agents@6.10.1`, with HOME, TMPDIR and the npm cache redirected into `$W/rea`.
  - `package.json` has no install scripts. No sudo. I skipped `rea setup` because it edits agent configs.
  - Launcher: `$W/rea-run/rea.sh`.
- **Runs.** Outputs are in `$W/rea-out/`.
  - `inspect-native-dispatch-metadata` on PreviewsInjection found 111 Swift types, 44 ObjC classes and 173 conformances. It named the types listed in Q2 (`JITBootstrapAgent`, `UVJITAgent`, `RunningAppEntryPoint`, `UVBSEndpointMonitor` implementing `BSServiceConnectionEndpointMonitorDelegate`, and others).
  - On XOJITExecutor it found `orc_rt_CWrapperFunctionResult` and `OS_xpc_object`.
  - On XCPreviewAgent it found only `ContentView` and `FrameworkAgentApp`.
  - `inspect-macho` showed imports of `PreviewsOSSupport.ShellToJITBootstrapAgentInterface` and `ShellService.agentJITBootstrapService`. I confirmed these with `nm` (`$W/strings/PreviewsInjection.nm.txt`).
  - Value over `nm`/`strings`: rea gives type kind, nesting, conformance pairs and vtable layout of stripped private types.
- **Failed.** Decompiling `__previews_injection_jit_link_entrypoint` returned `provider_unavailable`.
  - `rea doctor --provider ghidra` reported: "12.1.4; accepted releases are 12.x (>=12.2)" and "17.0.17 ... accepted a 64-bit full JDK 21 or newer".
  - I did not start Hopper. It would open a GUI app and write its own settings.
- **Side effect outside the output path.** One early `npm view rea-agents` ran with the real HOME. It wrote `~/.npm/_logs/2026-11-21T08_14_33_072Z-debug-0.log` and registry metadata into `~/.npm/_cacache`. These were not deleted.

---

### Q4. LLDB as an injection path

#### Commands

- `process load <path>` loads a shared library into the process (`help process load`). **Verified.**
- `image load` is an alias of `target modules load`. It only sets section load addresses in the debugger and does not inject code (`help image load`). **Verified.**
- Python API: `SBProcess.LoadImage(SBFileSpec, SBError)` and `SBCommandInterpreter.HandleCommand("expr ...")`.
- LLDB here: `lldb-2103.0.34.407`, Swift 6.4.2.

#### Measured

I tested on a macOS host process, not the simulator. No simulator was booted, and booting one would write outside the output path.

- Setup:
  - `host` was built with `-Onone -Xfrontend -enable-implicit-dynamic -enable-testing`. It prints `greet()` every 250 ms.
  - Each patch dylib has `@_dynamicReplacement(for: greet())` and was linked with `-undefined dynamic_lookup`. Swift compile of a one-function patch took 0.30 s.
  - Scripts: `$W/lldb_api_timing.py` and `$W/lldb_two_loads.py`. Outputs: `$W/lldb-test/host*.out`.
- Results:

| Step | Time |
|---|---|
| `lldb -b -p PID -o "process load patch.dylib" -o detach` (CLI, cold start) | 8.7 s total. Output switched `v1` → `v2`. |
| Python API `AttachToProcessWithID` | 0.60–0.77 s |
| `LoadImage(patch3.dylib)` | 0.03–0.41 s |
| `LoadImage(patch4.dylib)`, same session | 0.44 s. The last loaded replacement wins (output `v1`×5 then `v4`×5). |
| `expr -l swift -- 1 + 2`, first and second | 0.057 s, 0.009 s (tiny binary, no SwiftUI) |
| `expr -l objc -- [[NSProcessInfo processInfo] processIdentifier]`, first | 0.82 s |
| `Detach` | < 0.11 s |

- Conclusions for a live loop:
  - Keep one persistent LLDB session through the Python API, or a resident `lldb` with `protocol-server start MCP`. Do not start the CLI per edit, because a cold start costs about 8 s.
  - Per edit, the cost is: stop, `LoadImage`, continue. That is under 0.5 s plus the swiftc time.
  - Swift `expr` for running code is fine for small calls. I did not measure it in a real SwiftUI app; the first Swift expression there loads many modules and is expected to take seconds (**inferred**).
- Catches:
  - Dynamic replacement needs the app compiled with `-enable-implicit-dynamic`. A normal Xcode 27.2 debug build has none: 0 replaceable symbols in `Gallery.debug.dylib` (**verified** above).
  - Private declarations also need `-enable-private-imports`.
  - SwiftUI `body` changes that alter the opaque type need `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES`.
  - Stopping the process with LLDB pauses the UI briefly.
- Simulator attach:
  - Simulator apps are ordinary macOS processes, so `process attach --pid` or `--name ... --waitfor` should work the same way (**inferred**, not run here).
  - Apple's Previews does not use LLDB. It uses its own XPC executor.

#### LLDB MCP

- Xcode 27 ships `$XC/Developer/usr/bin/lldb-mcp`. Release note: "LLDB now ships with an MCP server (lldb-mcp)" (https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes, Debugging).
- Tools: `session_create`, `command`, `sessions_list` and `session_close`.
- Inside a running LLDB, `protocol-server start MCP [listen://host:port]` exposes that session (https://lldb.llvm.org/use/mcp.html). **Verified:** `help protocol-server` works in this LLDB.

---

### Q5. New in Xcode 26 and 27

All entries below are **verified** against release notes or local binaries.

- **Xcode 26.3: agentic coding and an MCP server.** Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes
  - `xcrun mcpbridge` is a stdio bridge to "Xcode's MCP tool service". Env: `MCP_XCODE_PID`, `MCP_XCODE_SESSION_ID` (`mcpbridge --help`).
  - `xcrun agent` is a shell script that runs `mcpbridge run-agent` (`cat $XC/Developer/usr/bin/agent`).
- **MCP tool names** in `$XC/PlugIns/IDEIntelligenceChat.framework` (`strings`):
  - `BuildProject`, `GetBuildLog`, `RunProject`, `StopProject`, `RunCodeSnippet`, `RenderPreview`, `RunSomeTests`, `RunAllTests`
  - `InvokeDebuggerCommand`, `GetConsoleOutput`
  - `DeviceInteractionStartSession`, `DeviceInteractionInstallAndRun`, `DeviceInteractionSynthesize`
  - `GetTargetBuildSettings`, `UpdateTargetBuildSetting`, `XcodeRead`, `XcodeWrite`, `XcodeUpdate`, and others.
  - None of them applies code changes to a running app.
- **Xcode 27.** Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
  - Agents can "boot simulators, install and launch apps, synthesize touch events, and capture screenshots".
  - New MCP tools let agents debug the active run (debugger console, run state).
  - Headless `xcrun mcp-server enable` (needs sudo; I did not run it).
  - `lldb-mcp`.
  - A Previews "Run as App" feature for macOS, under the Live canvas mode menu ("Fixed an incorrect error banner ... Run as App preview feature").
- **Xcode 27.2.** "A clearer error ... when ... another user account on this Mac owns the Previews JIT directory." The JIT directory is `/private/var/OOPJit` (`ls -ld` shows `drwxrwxrwx root admin`; listing its contents returns "Operation not permitted"). Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes
- **Running App Preview exists in the binaries:** `RunningAppPreviewManager` and "Launch running app preview" (PreviewsPipeline), `Ultraviolet.RunningAppPreview` (PreviewsMessagingOS), and `RunningAppEntryPoint` in the **iOS** simulator's PreviewsInjection. Whether Xcode offers it for iOS is unknown.
- **Not found:** any "hot reload" or "apply code changes" feature for a normal Run session. I grepped `IDEIntelligenceChat` and `IDEKit` for `hot.?reload|hot.?swap|live.?reload|fix.?and.?continue`. The only hit was `ApplyChangesAction`, which is the chat diff-apply UI.

---

### Q6. Driving Apple's preview JIT against a full running app

#### What the evidence shows

- The machinery already runs a full app. In XOJIT mode the preview process is the real app stub, with the whole app's code JIT-linked. `RunningAppEntryPoint` and `__previews_injection_run_user_entrypoint` run the app's own `main`. Hot swap then works on that process.
- So "full app with live reload" is technically what Previews does in Running App Preview and macOS "Run as App". **Inferred** from symbols; Apple does not document it.
- XOJIT has a public-looking Swift API, including an in-process `XOJIT.init()`, and `ReplacementManager`.

#### Blockers

1. **Launch-time only.**
   - The app must start under PreviewShell with the injected env, the decoy `__preview.dylib` and a JIT bootstrap connection id.
   - An app already started by Run or `simctl launch` has its real debug dylib loaded by dyld. Its code is not under XOJIT, so `ReplacementManager` has nothing to redirect (**inferred**).
2. **Private, unversioned protocols.**
   - The transport consists of BoardServices endpoints (`com.apple.uv.*`), previewsd Mach services and plist `Ultraviolet.*` payloads.
   - XOJIT is `xojit-84` with no public headers or module interface. These will change between Xcode releases.
3. **Entitlements.**
   - PreviewShell has `com.apple.private.oop-jit.loader = previews`.
   - previewsd has `com.apple.frontboard.launchapplications` and other private entitlements.
   - Simulator binaries carry entitlements in an embedded `__TEXT,__entitlements` section. `codesign -d --entitlements -` prints an empty dict for them. Whether sim services check these entitlements is unknown.
   - On device, out-of-process JIT needs Apple-only entitlements (**inferred**).
4. **dyld pseudodylibs need development mode.**
   - `_dyld_pseudodylib_register` returns null unless `config.security.allowDevelopmentVars` is set. That flag comes from AMFI (`AMFI_DYLD_OUTPUT_ALLOW_DEVELOPMENT_VARS`).
   - Source: https://github.com/apple-oss-distributions/dyld/blob/dyld-1378/dyld/DyldAPIs.cpp (about line 3092) and `dyld/DyldProcessConfig.cpp` line 902. The same check appears in `strings $RR/usr/lib/dyld_sim`.
   - Debug sim builds with `get-task-allow` likely pass (**inferred**).
5. **No decompilation done.** I did not decompile the message formats or the replacement semantics (see Q3).

#### Feasible paths, most practical first

1. Ask Xcode for a Running App Preview of the app scene, if it can be triggered (needs UI or private API).
2. Reproduce the design with public parts:
   - Our own decoy dylib and loader.
   - Upstream LLVM ORC (`llvm-project`, open source), the same technology XOJIT wraps.
   - swift-build's `generatePreviewInfo` logic to get per-file frontend commands.
3. Skip the JIT. Use `-enable-implicit-dynamic` plus `@_dynamicReplacement` patch dylibs loaded through LLDB or an in-app loader. I verified this end to end on macOS.

---

### What we can reuse

| Item | Status | How |
|---|---|---|
| Swift dynamic replacement + `dlopen` | Verified (macOS process) | Add `-Xfrontend -enable-implicit-dynamic` (and `-enable-private-imports`) to Debug `OTHER_SWIFT_FLAGS`. Compile only the edited file into a patch dylib with `@_dynamicReplacement(for:)`. Load it with `SBProcess.LoadImage` (0.03–0.44 s) or an in-app `dlopen`. |
| Opaque type erasure for SwiftUI bodies | Verified flag mapping | Set `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES` in Debug (`-enable-experimental-feature OpaqueTypeErasure`). |
| Debug dylib exports internals | Verified | Patch dylibs can bind to `@rpath/<App>.debug.dylib` internal symbols with `-undefined dynamic_lookup`. |
| Per-file compile command | Verified source | Copy swift-build's preview-info logic: take the original frontend command, replace the primary input through `-output-file-map`, drop sidecar outputs. This gives the fastest correct single-file recompile. |
| Literal-only updates without compile | Public API exists, key format unknown | `__designTimeString`/`__designTimeApplyIncrementalValues` are public in DeveloperToolsSupport. We would need our own rewrite that wraps literals and an exact key format. |
| Persistent debugger channel | Verified | Python `SBDebugger` session, or `protocol-server start MCP` plus `lldb-mcp`. Avoid the CLI cold start (8.7 s). |
| Xcode MCP tools | Verified names | `BuildProject`, `RunProject`, `InvokeDebuggerCommand`, `GetConsoleOutput`, `DeviceInteraction*` and `RenderPreview` for the agent loop. None does hot reload. |
| ORC design reference | Inferred | XOJIT is ORC with SimpleRemoteEPC over XPC, MachOPlatform and dyld pseudodylibs. Upstream ORC can do the same in our own process. |

### Open questions

1. What is the exact thunk source and `__designTime*` key format? I found no `*.preview-thunk.*` file in DerivedData, and `/private/var/OOPJit` is not readable. To capture one, run a preview while watching `$TMPDIR` or `OOPJit` with permission.
2. Does setting `defaults write com.apple.dt.Xcode UVLogLaunchEnvironment -bool YES` log the full agent launch env? I did not run it because it writes Xcode defaults. The domain is **inferred**.
3. Can Xcode 27 start a Running App Preview for iOS, and how? Look in PreviewsXcode or IDE menus, or decompile `RunningAppPreviewManager`.
4. Can a debug sim app `dlopen` `XOJIT.framework` and use `XOJIT.init()` in-process, without the oop-jit entitlement? This needs a test app in a simulator.
5. What do LLDB attach and `LoadImage` cost on a real SwiftUI app in the iOS 27.2 simulator, including the first Swift `expr`? This needs a booted simulator, which this research slice did not allow.
6. What happens when replacing a function whose signature or stored layout changes? Dynamic replacement only swaps bodies, and Previews then falls back to "relaunch". The relaunch rules in PreviewsPipeline need decompiling. That needs Ghidra 12.2 or later with JDK 21, or Hopper.

---

## Part C: verification and control loop for a hot-reloaded iOS Simulator app

Scope: how a terminal coding agent sees and drives the simulator app after each hot reload. Code injection and Xcode Previews internals are out of scope (other research slices).

Environment checked: macOS 27.2 (Darwin 27.2.0), Xcode 27.2 (27B52), iOS 27.2 runtime. Date: 2026-11-21.

Method and limits:
- Local commands were read-only. No simulator was booted, erased, or changed. No simulator was booted at research time (`xcrun simctl list devices booted` showed none), so I did **not** measure `simctl io screenshot` on this machine. All simulator latency numbers below come from cited third-party measurements.
- GitHub line numbers refer to the default branch on 2026-11-21. They move over time.
- "Inferred" marks a claim that I did not verify against a primary source or a run.

### Key findings

1. `simctl` gives screenshots (`io screenshot`, also to stdout), video, logs (`spawn ... log stream`), launch with console capture, deep links, permissions, appearance, and status-bar freezing. It has **no** tap, type, or hierarchy command.
2. All maintained non-XCUITest tools (idb, AXe, sim-use, MobileBuildMCP, ios-simulator-mcp) use the same private stack: `AccessibilityPlatformTranslation` plus CoreSimulator for the tree, and SimulatorKit `SimDeviceLegacyHIDClient` Indigo messages for input. idb is the root; AXe and sim-use vendor idb's frameworks.
3. Xcode 27.2 ships its own agent device tools: `DeviceInteractionStartSession`, `DeviceInteractionSynthesize`, `DeviceInteractionInstallAndRun`, `DeviceInteractionEndSession`. They return a screenshot, a UI hierarchy with tap points, and a console log path. They use XCTest automation internally (inferred from strings). Whether `xcrun mcpbridge` exposes them to external agents is not verified.
4. The best existing reference for "the app is idle now" is idb's in-app shim (`IDB_IDLE_SYNC=1`). It reports idle after 100 ms with no main-thread work, animation, scroll, or ignored input, over a host Unix socket.
5. An in-process dylib gives data no out-of-process tool can: SwiftUI view types and values through `_UIHostingView._viewDebugData()`, the UIKit class tree, app state, and a reload generation counter. Out-of-process accessibility sees what the user sees, including system alerts and keyboards. Use both.
6. The cheapest "my change is on screen" signal is a hierarchy delta (expected text or identifier appears), confirmed by a pixel-diff bounding box that overlaps the changed view's frame. Send the model a cropped image only when the delta is ambiguous.
7. From cited numbers, the post-reload part of the loop (idle wait, frame grab, hierarchy, diff) can fit in about 150 to 250 ms with persistent daemons. With per-call CLI tools it is about 0.5 to 1 s (inferred from the step numbers in section 6).

### 1. `xcrun simctl` on Xcode 27.2

Source for every row: local `xcrun simctl help` and `xcrun simctl help <subcommand>` on Xcode 27.2 (27B52).

| Command | What it gives the loop | Notes |
|---|---|---|
| `simctl io <dev> screenshot [--type=png\|jpeg\|...] [--display=..] [--mask=..] <file or ->` | Full-screen capture | `-` writes the image to stdout, so no temp file is needed. `--mask` controls the rounded-corner mask. |
| `simctl io <dev> recordVideo [--codec=h264\|hevc] [--force] <file>` | Video of an animation or transition | Prints `Recording started` to stderr after the first frame. Stop with SIGINT. |
| `simctl io <dev> enumerate [--poll]` / `poll` | Lists IO ports and polls them for events | Not tested. Whether it signals display changes is an open question. |
| `simctl launch [--console\|--console-pty] [--stdout=..] [--stderr=..] [--terminate-running-process] <dev> <bundle> [argv]` | Launch plus stdout/stderr capture | `--console` blocks and forwards signals. `--terminate-running-process` is a clean relaunch. |
| `SIMCTL_CHILD_<NAME>=value` in the caller's environment | Passes env vars to `launch` and `spawn` children | This is how a debug dylib is armed, for example `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=...` or `SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=...` (see section 4). |
| `simctl spawn <dev> log stream --level debug --predicate 'subsystem == "<id>"'` | OSLog lines from the app | `spawn` runs the runtime's own `/usr/bin/log`. That binary exists in the iOS 26.5 runtime root (local `ls`); iOS 27.2 is inferred to match. Host `log stream` supports `--style ndjson` (local `/usr/bin/log help stream`); the simulator `log` is inferred to support it too. |
| `simctl spawn <dev> notifyutil -w <name>` | Waits for a Darwin notification posted by the app | `notifyutil` exists in the iOS 26.5 runtime `/usr/bin` (local `ls`). Use as a "reload done" signal (inferred, not run). |
| `simctl openurl <dev> <url>` | Jump straight to a screen by deep link | ios-simulator-mcp recommends this to cut navigation steps ([README L433-L463](https://github.com/joshuayoes/ios-simulator-mcp/blob/main/README.md#L433-L463)). |
| `simctl privacy <dev> grant <service> <bundle>` | Removes permission dialogs that would block screenshots | Some changes terminate the running app (help text). |
| `simctl ui <dev> appearance [light\|dark]`, `increase_contrast`, `content_size [increment\|decrement\|<size>]` | Verify a change under dark mode, contrast, and Dynamic Type | |
| `simctl status_bar <dev> override --time <str> ...` | Freezes the clock and indicators | Removes the largest source of pixel-diff noise (section 5). |
| `simctl pbcopy` / `pbpaste` | Pasteboard in and out | Useful for text entry fallback. |

Not in `simctl`: tap, swipe, type, or any view/accessibility hierarchy. Input needs another tool (section 2).

Related Apple CLI: in Xcode 27.2, `xcrun devicectl list devices` lists simulators with Reality `simulated` (local run). `devicectl device capture screenshot`, `device capture screen-record`, and `device notification post|observe` exist (local `xcrun devicectl device <cmd> --help`). Using them against a booted simulator is inferred, not tested.

### 2. UI inspection and input without XCUITest

#### How the tools do it

All maintained tools share one private stack. I verified the symbols locally and in idb source.

- **Accessibility tree, host side.** `AXPTranslator` in the private `AccessibilityPlatformTranslation` framework translates the app's tree on the Mac. Requests go to `com.apple.CoreSimulator.accessibility`, a service of CoreSimulatorBridge inside the simulator. The fallback is `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`. Sources: [idb FBSimulatorAX README L53-L77](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L53-L77), [AXTranslationTransport.swift L38-L80](https://github.com/meta/idb/blob/main/FBSimulatorAX/Translation/AXTranslationTransport.swift#L38-L80). Local check: `strings` on `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator` shows `sendAccessibilityRequestAsync:completionQueue:completionHandler:`. `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework` exists on this Mac.
- **Accessibility tree, guest side.** idb's `axbridge` backend spawns its own `SimulatorFrameworkBridge` helper inside the simulator. It reads the whole tree in one round trip, at XCUITest granularity, and sets the app into automation mode ([FBSimulatorAX README L79-L99](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L79-L99)).
- **Input.** SimulatorKit's runtime-only Swift class `SimDeviceLegacyHIDClient` sends `IndigoHIDMessage` bytes to the `IndigoHIDRegistrationPort` ([SimulatorIndigoHIDClient.swift L14-L60](https://github.com/meta/idb/blob/main/FBSimulatorControl/HID/SimulatorIndigoHIDClient.swift#L14-L60)). The class moved between frameworks across Xcode versions, so idb resolves it by name at runtime. Local check: `nm -gU` on `/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit` exports `_IndigoHIDMessageForMouseNSEvent`, `_IndigoHIDMessageForKeyboardArbitrary`, `_IndigoHIDMessageForButton`, and `SimDeviceLegacyHIDClient.send(message:...)`. idb and AXe also have a newer DTUHID touch path (`FBSimulatorControl/HID/SimulatorDTUHIDConnection.swift` in idb; AXe [README L130](https://github.com/cameroncooke/AXe/blob/main/README.md#L130) mentions "the DTUHID touch service").
- **Framebuffer.** idb reads the display IOSurface directly and registers per-frame and damage callbacks (`registerScreenCallbacks(... frameCallback:, surfacesChangedCallback:)`) ([FramebufferSurface.swift L65-L130](https://github.com/meta/idb/blob/main/FBSimulatorControl/Framebuffer/FramebufferSurface.swift#L65-L130)). A frame callback is a "screen changed" signal with no polling.

Risk: every tool here depends on private APIs. They break when Xcode moves classes. idb documents this for `SimDeviceLegacyHIDClient` (L14-L15 above).

#### Measured costs (from the sources)

| Read | Cost | Source |
|---|---|---|
| idb host `ax` read, iOS 27.0 Calendar, 159 elements | ~99 ms (one XPC round trip per element) | [FBSimulatorAX README L59](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L59) |
| idb `axbridge` read, 167-element Settings, idle | ~30 ms (one round trip) | [README L106](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L106) |
| Reachability keys (`interactable`, `occluded_by`) | ~1.6 s for the tree; ~18 ms for one point | [README L123](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L123), [L314](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L314) |
| AXe read then tap, iPhone 17 Pro, Settings | ~290 ms one-off; ~176 ms via `axe serve`; ~146 ms with `--minimal-keys` | [AXe README L161](https://github.com/cameroncooke/AXe/blob/main/README.md#L161) |
| simframe host daemon reading the tree itself versus shelling out to an external tool | ~45 ms versus ~203 ms, same screen (self-reported) | [simframe article](https://dev.to/lvlrsajjad/agents-shouldnt-blink-559a) |
| sim-use observe then act | ~300 ms after warm-up; ~200 ms init amortized by a daemon | [sim-use README L81](https://github.com/lycorp-jp/sim-use/blob/main/README.md#L81), [L536](https://github.com/lycorp-jp/sim-use/blob/main/README.md#L536) |

Two details change results. Host reads return the VoiceOver view: 14 elements on an iOS 27.0 Settings screen versus 152 elements from the in-guest XCTest vocabulary ([README L138](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L138)). Without automation mode, UIKit collapses subtrees; one screen went from 12 to 58 elements with identifiers when the mode was on ([README L349](https://github.com/meta/idb/blob/main/FBSimulatorAX/README.md#L349)).

#### Tools

- **idb (now `meta/idb`).** The root implementation. Backends `ax`, `ax-coresimulator`, `axbridge`. It also has an in-app shim, `libShimulator`, injected with `DYLD_INSERT_LIBRARIES`, that provides idle sync (section 4) and a Swift code-injection REPL ([FBSimulatorCodeInjection README L1-L20](https://github.com/meta/idb/blob/main/FBSimulatorCodeInjection/README.md#L1-L20)). Very active: release v1.7.8 on 2026-11-01, commits on 2026-11-21 (GitHub API). Local install is stale: `idb_companion` 1.1.8, built 2022-08-12, and no `idb` client. ios-simulator-mcp says 1.1.8 lacks `--api axbridge` ([README L103](https://github.com/joshuayoes/ios-simulator-mcp/blob/main/README.md#L103)).
- **AXe (`cameroncooke/AXe`).** CLI over a vendored copy of idb's `FBControlCore` and `FBSimulatorControl` ([README L336](https://github.com/cameroncooke/AXe/blob/main/README.md#L336)). Has `describe-ui`, `tap --id/--label`, `type`, `batch`, `screenshot`, `stream-video`, and `serve` (one process, JSON per line, [L145-L161](https://github.com/cameroncooke/AXe/blob/main/README.md#L145-L161)). `--agent` mode returns refs and, after each action, "the settled screen as a new capture" ([L279](https://github.com/cameroncooke/AXe/blob/main/README.md#L279)). v2.1.1 on 2026-11-19. License changed to GPL-3.0-only after v2.0.4 ([L376-L384](https://github.com/cameroncooke/AXe/blob/main/README.md#L376-L384)); running it does not affect the app's license, but embedding its code does. Local install is 1.8.0.
- **sim-use (`lycorp-jp/sim-use`).** Apache-2.0. Statically links idb XCFrameworks ([README L100](https://github.com/lycorp-jp/sim-use/blob/main/README.md#L100)). Prints a compact outline with `@N` aliases, "~16x more compact than a raw JSON accessibility tree" ([L78](https://github.com/lycorp-jp/sim-use/blob/main/README.md#L78)). Pushed 2026-11-19.
- **simframe (`lvlrSajjad/simframe`).** MIT, 0 stars, pushed 2026-10-05. A Swift daemon reads the framebuffer IOSurface on display damage and runs Vision OCR ([README L182-L183](https://github.com/lvlrSajjad/simframe/blob/main/README.md#L182-L183)). Interesting design, unproven project.
- **Apple Xcode 27.2 `DeviceInteraction*` tools.** See section 3. These are XCTest-based (inferred) but need no test bundle from the user.

### 3. MCP servers

#### Xcode 27.2 (`xcrun mcpbridge`)

Apple documents setup only: `claude mcp add --transport stdio xcode -- xcrun mcpbridge`, with Xcode > Settings > Intelligence > "Allow External Agents to Use Xcode Tools" ([Apple: Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)). The page lists no tools. Local `xcrun mcpbridge --help` confirms the stdio bridge, `MCP_XCODE_PID`, and `run-agent`. `xcrun mcp-server` (headless preview, Xcode 27 Beta 5+) reports `Permission: enabled`, `mcp-server: not running` on this Mac (local `xcrun mcp-server status`).

I did not call `tools/list`, because connecting raises Xcode UI. I built the inventory from plug-in registrations instead. Every Xcode MCP tool I recognized (`BuildProject`, `XcodeRead`, `RenderPreview`, `RunProject`, `GetConsoleOutput`) is registered at the extension point `Xcode.DVTFoundation.StatelessAction`. The device tools use the same point (local `plutil -p` on each `*.xcplugindata`). Inferred: all of the following are served by the same MCP tool service.

Tools useful for a reload-verify loop:

| Tool (Xcode 27.2) | Registered in | What it does (from its own description strings) |
|---|---|---|
| `DeviceInteractionStartSession` / `DeviceInteractionStartWorkspaceSession` | `IDEDeviceInteraction` | "finds and (if necessary) boots a desired device"; the no-workspace form is for "an already-installed app" |
| `DeviceInteractionSynthesize` | `IDEDeviceInteraction` | "Synthesizes device events (tap, swipe, type, etc.) on a physical device or simulator" then "captures a screenshot and UI hierarchy". Returns "Path to a screenshot file with small resolution", "Path to the captured full-size screenshot", "Path to the captured UI hierarchy file (incl. device orientation)", and "Path to the file where collected console logs of the application are stored". An empty command only captures state. |
| `DeviceInteractionInstallAndRun` | `IDEDeviceInteraction` | "Builds, installs, and starts the current application" |
| `DeviceInteractionEndSession` | `IDEDeviceInteraction` | Ends the session. Strings warn that an open session "is expensive and affects the user-facing UI". |
| `RunProject` / `StopProject` | `IDEKit` | "Builds and runs the current scheme ... equivalent to pressing the Run button (Cmd+R)" / Stop |
| `GetConsoleOutput` | `IDEKit` | "Retrieves console output (stdout, stderr, OSLog) from a running or completed app launch session. Supports regex filtering, severity filtering" |
| `InvokeDebuggerCommand` | `IDEConsoleKit` | "Sends an lldb command to Xcode's active debugging session and returns the output" (read app state) |
| `RenderPreview` | `PreviewsXcode` | Preview snapshot (out of scope here) |
| `XcodeListRunDestinations`, `XcodeSwitchRunDestination`, `GetBuildLog`, `XcodeListNavigatorIssues` | `IDEKit` | Pick the simulator, read build errors |

Source for names: local `plutil -p` on `IDEKit.xcplugindata`, `IDEDeviceInteraction.xcplugindata`, `PreviewsXcode.xcplugindata`, `IDEConsoleKit` plug-in data. Source for descriptions: local `strings` on `/Applications/Xcode.app/Contents/PlugIns/IDEDeviceInteraction.framework/Versions/A/IDEDeviceInteraction` and `.../Frameworks/IDEKit.framework/Versions/A/IDEKit`.

Release notes confirm the feature: "Agents can now boot simulators, install and launch apps, synthesize touch events, and capture screenshots to verify UI behavior. (175179787)" and new MCP tools to "manipulate the active run state, interacting with and reading the contents of the debugger console" ([Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes), Coding Intelligence). LLDB also ships `lldb-mcp` (same notes, Debugging). The binary is at `/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-mcp` (local).

How it works (inferred from strings in the same binary): `enableAutomationModeWithError:`, `waitForQuiescenceOfApplicationWithBundleId:error:`, `XCUIElementSnapshot`, `XCSynthesizedEventRecordBuilder`, "Host automation mode failed to initialize. Ensure no other tests are running". So it drives the simulator through XCTest's remote automation without a user test bundle. The hierarchy format is one line per element with a frame and a tap point, for example `UIButton "Login" {{110, 205}, {30, 20}}, hitPoint: {125.0, 215.0}`. The bundled skill text says "Tools are designed to complete once animations are done", so quiescence is built in.

Fit for our tool: after a hot reload there is no reinstall, so the loop would be `DeviceInteractionStartSession` once, then `DeviceInteractionSynthesize` with an empty command after each reload. Requirements: Xcode running, a permission grant, and XCTest automation mode on the app (side effects on a hot-reloaded app are unknown).

#### MobileBuildMCP (formerly XcodeBuildMCP)

`cameroncooke/XcodeBuildMCP` now redirects to `getsentry/MobileBuildMCP` (GitHub API). npm package `mobilebuildmcp`, MIT ([README L4-L20](https://github.com/getsentry/MobileBuildMCP/blob/main/README.md#L4-L20)). v2.7.1 on 2026-09-23. It bundles AXe for UI automation; `.axe-version` pins `1.8.0`. Local install: `xcodebuildmcp` 2.3.2.

Tools for the loop (from `manifests/tools/*.yaml`): `build_run_sim`, `launch_app_sim`, `stop_app_sim`, `screenshot`, `snapshot_ui`, `wait_for_ui`, `tap`, `type_text`, `swipe`, `batch`, `gesture`, `long_press`, `record_sim_video`, `sim_statusbar`, `set_sim_appearance`, `debug_attach_sim`, `debug_lldb_command`, `xcode_ide_list_tools`, `xcode_ide_call_tool` (proxy to Apple's `mcpbridge` tools).

Implementation details worth copying:
- `screenshot` runs `xcrun simctl io <id> screenshot <png>` and then `sips -Z 800 -s format jpeg -s formatOptions 75` ([screenshot.ts L241](https://github.com/getsentry/MobileBuildMCP/blob/main/src/mcp/tools/ui-automation/screenshot.ts#L241), [L268-L280](https://github.com/getsentry/MobileBuildMCP/blob/main/src/mcp/tools/ui-automation/screenshot.ts#L268-L280)).
- `wait_for_ui` "settled" means the accessibility element signature has not changed for `settledDurationMs` ([wait-predicate.ts L333-L349](https://github.com/getsentry/MobileBuildMCP/blob/main/src/mcp/tools/ui-automation/shared/wait-predicate.ts#L333-L349)).
- Logs: `simctl launch --console-pty` for stdout/stderr, plus `simctl spawn <udid> log stream --level=debug --predicate 'subsystem == "<bundleId>"'` for OSLog ([simulator-steps.ts L172-L182](https://github.com/getsentry/MobileBuildMCP/blob/main/src/utils/simulator-steps.ts#L172-L182), [L376-L387](https://github.com/getsentry/MobileBuildMCP/blob/main/src/utils/simulator-steps.ts#L376-L387)).

#### ios-simulator-mcp (`joshuayoes/ios-simulator-mcp`)

MIT, TypeScript, v2.2.1 on 2026-11-10. Wraps idb (`idb_companion` plus the `fb-idb` Python client) ([README L470](https://github.com/joshuayoes/ios-simulator-mcp/blob/main/README.md#L470)). Tools: `get_booted_sim_id`, `open_simulator`, `ui_describe_all`, `ui_describe_point`, `ui_find_element`, `ui_tap`, `ui_type`, `ui_swipe`, `ui_view` (compressed screenshot returned as image content), `screenshot`, `record_video`, `stop_recording`, `install_app`, `launch_app`, `terminate_app`, `open_url`, `list_apps` ([README L20-L356](https://github.com/joshuayoes/ios-simulator-mcp/blob/main/README.md#L20-L356)). Known iOS 27.2 issue: the simulator cannot show the "Allow Paste" prompt, so paste-mode typing falls back to the edit menu and takes 8 to 13 s ([L103](https://github.com/joshuayoes/ios-simulator-mcp/blob/main/README.md#L103)).

#### mobile-mcp (`mobile-next/mobile-mcp`)

Apache-2.0, 1.0.18 on 2026-11-18. Tools include `mobile_list_elements_on_screen` and `mobile_take_screenshot` (now with a clip region) ([README L124-L126](https://github.com/mobile-next/mobile-mcp/blob/main/README.md#L124-L126)). iOS simulators go through `mobilecli` (Go) ([README L551](https://github.com/mobile-next/mobile-mcp/blob/main/README.md#L551)), which installs a `com.mobilenext.devicekit-iosUITests.xctrunner` agent ([mobilecli README L381](https://github.com/mobile-next/mobilecli/blob/main/README.md#L381)). So it is XCUITest-based underneath (inferred from the bundle ID).

### 4. In-process approach (debug dylib with a local server)

#### Transport and loading

- **Loopback TCP works.** LookinServer listens on `127.0.0.1:47164-47169` inside the simulator, and the Mac app connects to it ([LookinDefines.h L42-L44](https://github.com/QMUI/LookinServer/blob/develop/Src/Main/Shared/LookinDefines.h#L42-L44), [LKS_ConnectionManager.m L92-L122](https://github.com/QMUI/LookinServer/blob/develop/Src/Main/Server/Connection/LKS_ConnectionManager.m#L92-L122)).
- **Host Unix sockets work.** idb's host serves `/tmp/idb-shimulator-<uid>/<UDID>.idle.sock` and the simulator app connects to it ([IdleSync README L34](https://github.com/meta/idb/blob/main/Shims/Shimulator/IdleSync/README.md#L34)). A Unix socket avoids port collisions between simulators.
- **Loading.** idb inserts its shim with `DYLD_INSERT_LIBRARIES` and keeps launchd's existing inserted libraries ([FBSimulatorCodeInjection README](https://github.com/meta/idb/blob/main/FBSimulatorCodeInjection/README.md), "Microphone injection"). With `simctl`, the same is `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<path> xcrun simctl launch ...` (help text, section 1). Linking the dylib in Debug builds is the simpler alternative.

#### What the dylib can read

- **UIKit tree.** Lookin walks all windows and then `CALayer.sublayers` ([LKS_HierarchyDisplayItemsMaker.m L30-L32, L95-L98](https://github.com/QMUI/LookinServer/blob/develop/Src/Main/Server/Others/LKS_HierarchyDisplayItemsMaker.m#L30-L98)). swift-snapshot-testing calls the private `recursiveDescription` selector ([UIView.swift L68-L90](https://github.com/pointfreeco/swift-snapshot-testing/blob/main/Sources/SnapshotTesting/Snapshotting/UIView.swift#L68-L90)). FLEX does the same walk with an in-app UI and no remote server ([README L9-L30](https://github.com/FLEXTool/FLEX/blob/master/README.md#L9-L30)).
- **SwiftUI tree.** The iOS 27.2 simulator SDK declares `final public func _viewDebugData() -> [SwiftUICore._ViewDebug.Data]` on `_UIHostingView` (local `SwiftUI.swiftinterface` L28006). `SwiftUICore` declares `_ViewDebug.Property` cases `type, value, transform, position, size, environment, phase, layoutComputer, displayList` (L19083-L19092), `_ViewDebug.Data: Encodable`, and `_ViewDebug.serializedData(_:) -> Data?` (L19183). Recording is gated by an environment variable. OpenSwiftUI's reimplementation reads `OPENSWIFTUI_VIEW_DEBUG` and then calls `Subgraph.setShouldRecordTree()` ([ViewDebug.swift L83-L93](https://github.com/OpenSwiftUIProject/OpenSwiftUI/blob/main/Sources/OpenSwiftUICore/View/ViewDebug.swift#L83-L93)). The real `SwiftUICore` binary in the iOS 26.5 simulator runtime contains the string `SWIFTUI_VIEW_DEBUG` (local `strings`). Inferred: launch with `SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=<bitmask>` to get SwiftUI type names, values, and frames. `_UIHostingView` is generic, and `_viewDebugData` is not `@objc`. A dylib must cast through a protocol that the dylib conforms `_UIHostingView` to (inferred, untested).
- **Accessibility in-process.** AccessibilitySnapshot parses the accessibility hierarchy in the app and exports it as Codable ([AccessibilityHierarchyParser.swift](https://github.com/cashapp/AccessibilitySnapshot/blob/main/Sources/AccessibilitySnapshot/Parser/Swift/Classes/AccessibilityHierarchyParser.swift), [AccessibilityHierarchy+Codable.swift](https://github.com/cashapp/AccessibilitySnapshot/blob/main/Sources/AccessibilitySnapshot/Parser/Swift/Classes/AccessibilityHierarchy%2BCodable.swift)). This gives the same labels as the out-of-process tree without XPC per element.
- **Snapshots.** Two APIs: `drawHierarchy(in:afterScreenUpdates: true)` and `layer.render(in:)` ([swift-snapshot-testing View.swift L908-L910, L994-L997](https://github.com/pointfreeco/swift-snapshot-testing/blob/main/Sources/SnapshotTesting/Common/View.swift#L908-L997); Lookin uses both, [CALayer+LookinServer.m L87-L89](https://github.com/QMUI/LookinServer/blob/develop/Src/Main/Server/Category/CALayer%2BLookinServer.m#L87-L89)). Both must run on the main thread. Apple says it cannot guarantee UIView APIs off the main thread and does not recommend real-time capture this way ([Apple forums 757394](https://developer.apple.com/forums/thread/757394)). For full-screen pixels, read the host framebuffer instead (section 2).
- **Idle detection.** idb's IdleSync shim is the reference design. A process is busy during main-thread wakes longer than 8 ms, `CALayer` animations up to 2 s, `UIScrollView` offset changes, and ignored interaction events. It is idle after 100 ms with none of these. It pushes `{"idleSince":...,"reasons":[]}` to the host and samples every 10 ms while a host is connected ([IdleSync README L8-L70](https://github.com/meta/idb/blob/main/Shims/Shimulator/IdleSync/README.md#L8-L70)).
- **Reload generation.** Hot-reload tools already broadcast completion. Inject listens to `Notification.Name("INJECTION_BUNDLE_NOTIFICATION")` ([InjectConfiguration.swift L80](https://github.com/krzysztofzablocki/Inject/blob/main/Sources/Inject/InjectConfiguration.swift#L80)). InjectionNext posts the same name (`App/InjectionNext/FrontendServer.swift`, found with GitHub code search). The dylib can count these notifications, then push `{generation, status, idleSince}` when the app is idle again.

#### In-process versus out-of-process

| | In-process dylib | Out-of-process accessibility (idb, AXe, Xcode tools) |
|---|---|---|
| Setup | Dylib in the app (Debug link or `DYLD_INSERT_LIBRARIES`) | Nothing in the app |
| Tree content | UIKit classes, frames, hidden or alpha state; SwiftUI view types and values (`_viewDebugData`); any app state | Accessibility labels, identifiers, roles, frames |
| Other processes (keyboard, alerts, share sheets) | Not visible | Visible (`axbridge` follows remote subtrees; README L97) |
| Reload awareness | Exact: generation counter and status | None; must infer from screen changes |
| Idle signal | Exact (run loop, animations, scroll) | Tree signature polling (MobileBuildMCP) or XCTest quiescence (Xcode) |
| Cost per read | No measurement found. Inferred: one main-thread pass with no XPC, so at or below the in-guest `axbridge` read (~30 ms) | 30 ms to 300 ms (section 2) |
| Failure modes | Hangs with the main thread; dies with the app; may change timing | Private host APIs break across Xcode versions; automation mode changes the tree |

Recommendation: use the dylib for reload state, idle, and the semantic tree. Use the host for pixels (framebuffer) and for input (HID). Fall back to host accessibility when the app is hung or a system alert is in front.

### 5. Fast visual diffing

#### Tools and cost

- **Framebuffer hash.** simframe hashes a downscaled framebuffer: grab 0.13 ms; grab plus downscale plus two hashes 6.74 ms median; "Did anything change?" ~2 ms (self-reported, iPhone 17 Pro, iOS 26.5; [article](https://dev.to/lvlrsajjad/agents-shouldnt-blink-559a), [README L110-L111](https://github.com/lvlrSajjad/simframe/blob/main/README.md#L110-L111)).
- **ImageMagick 7.1.2-10** (installed locally). `magick compare -list metric` lists `AE DPC DSSIM Fuzz MAE MEPP MSE NCC PAE PHASE PHASH PSNR RMSE SSIM`. Local measurement on synthetic 1206x2622 8-bit PNGs: `magick a.png b.png -compose difference -composite -colorspace gray -threshold 2% -format '%@' info:` returned `401x101+100+1000`, the exact changed rectangle, in 0.12 s wall time, process start included. `PHASH` and `SSIM` took 0.79 s and 0.84 s on 16-bit 16 MB images.
- **odiff** v4.5.0 (2026-07-23). Zig with SIMD (NEON included), ignore regions, antialiasing filter, and a `--server` mode that removes process spawn ([README L19-L40, L71-L98](https://github.com/dmtrKovalenko/odiff/blob/main/README.md#L19-L98)). Its benchmark: 1.17 s versus 7.7 s (pixelmatch) and 8.9 s (ImageMagick) on a full-page web screenshot ([L356-L366](https://github.com/dmtrKovalenko/odiff/blob/main/README.md#L356-L366)).
- **pixelmatch.** Anti-aliasing detection and a perceptual color metric (OKLab, HyAB) ([README](https://github.com/mapbox/pixelmatch/blob/main/README.md)). JavaScript, a few hundred lines; useful to port into the daemon.

#### Noise to remove first

- **Status bar clock.** The clock alone produced a mean difference of 0.0039, just under simframe's 0.004 change threshold. An iOS switch flip produced 0.001348, below the threshold, and was caught only by a per-region check (0.043) ([simframe article](https://dev.to/lvlrsajjad/agents-shouldnt-blink-559a)). So: freeze the bar with `simctl status_bar override --time`, mask the status bar, and use region or bounding-box diffs, not a global mean.
- **Animations and the caret.** Capture only after the idle signal (section 4). Inferred: a blinking caret causes small diffs; mask the focused text field's caret rect or wait for one full blink period.

#### Which signals show "my change is on screen"

Ordered by cost and reliability:

1. **Reload status and generation** from the dylib. This proves the new code loaded. It does not prove the screen changed.
2. **Hierarchy delta.** The expected label, identifier, or SwiftUI value appears, disappears, or changes. This is deterministic and costs a few hundred text tokens (sim-use's outline is ~16x smaller than raw JSON, README L78).
3. **Pixel-diff bounding box** that intersects the frame of the changed node from step 2. This proves the change rendered where expected.
4. **"Generation increased but no pixels changed."** The reload applied but the view did not re-render. Report it as a distinct state (the Inject library exists to force this re-render; inferred as a common case).
5. **Cropped image to the model.** Only for visual properties (color, spacing, clipping) or when 2 and 3 disagree.

Image token cost uses `ceil(w/28) * ceil(h/28)`; models from Claude 4.7 on downscale to a 2,576 px long edge and 4,784 tokens ([Claude vision docs](https://platform.claude.com/docs/en/build-with-claude/vision), "Resolution and token cost"). Computed for an iPhone 17 Pro screenshot:

| Image | Tokens |
|---|---|
| Full 1206x2622 (downscaled to 1185x2576) | 3,956 |
| MobileBuildMCP size, long edge 800 (368x800) | 406 |
| Points size 402x874 | 480 |
| Crop to a 600x300 diff box | 242 |

### 6. Design: shortest loop from "file saved" to "verified"

#### Components

- **App side:** a debug dylib. It counts reload notifications, tracks idle (IdleSync design), serves the UIKit and SwiftUI tree and app state, and pushes events over a host Unix socket.
- **Host side:** one long-lived verify daemon per simulator. It subscribes to framebuffer frame callbacks (idb `FramebufferSurface` pattern), keeps a HID client and an accessibility connection warm, tails `log stream --style ndjson`, and holds the dylib socket. Persistent processes remove start-up cost: AXe shows ~290 ms one-off versus ~176 ms via `serve` for read plus tap (README L161).
- **Agent side:** one blocking tool, for example `reload_and_verify({file, expect})`. It returns `{generation, reload_status, compile_errors, idle_ms, changed_bbox, tree_delta, new_log_lines, crash, screenshot_crop_path}`.

#### Steps and latency

| Step | Mechanism | Latency | Basis |
|---|---|---|---|
| 1. File saved, change detected | FSEvents watcher | not measured | |
| 2. Compile and inject | other research slices | not covered here | |
| 3. App reports "generation N applied" | dylib push over Unix socket | < 1 ms | inferred |
| 4. Wait until idle | IdleSync-style tracker | ≥ 100 ms quiet window, plus any animation | [IdleSync README L27](https://github.com/meta/idb/blob/main/Shims/Shimulator/IdleSync/README.md#L27) |
| 5a. Pixels, fast path | framebuffer IOSurface, downscale, hash | ~7 ms | simframe article (self-reported) |
| 5b. Pixels, CLI path | `simctl io screenshot` (+ downscale) | ~130 ms (210 ms) | [simframe README L102](https://github.com/lvlrSajjad/simframe/blob/main/README.md#L102), article |
| 6a. Tree, in-app | dylib walk | not measured; inferred ≤ 30 ms | inferred from the `axbridge` in-guest read |
| 6b. Tree, host | idb `axbridge` / `ax` | ~30 ms / ~99 ms | FBSimulatorAX README L106, L59 |
| 7. Diff against pre-reload frame | hash compare, then bbox | ~2 ms; 120 ms with ImageMagick CLI | simframe README L111; local measurement |
| 8. Logs since the reload | buffered `log stream` | ~0 ms extra (already streaming) | inferred |

Total for steps 3 to 8: about 150 to 250 ms on the fast path (100 ms idle floor + 7 + 30 + 2, plus slack). About 0.5 to 1 s on the CLI path (idle polling + 130 to 210 + 100 to 300 + 120). Both totals are inferred sums of the cited step numbers. The model's own turn (reading 250 to 4,000 image tokens plus the tree) will dominate wall time; that is not measured here.

#### Failure detection

- Compile failure: from the injection compiler (other slices). Return it in `reload_status` without capturing.
- Crash: the `launch --console-pty` child exits, the dylib socket drops, and a crash report appears. On simulators, `mobilecli` reads crash reports from `~/Library/Logs/DiagnosticReports/` ([mobilecli README L475](https://github.com/mobile-next/mobilecli/blob/main/README.md#L475)).
- Hang: no idle event within a budget, while the frame callback still ticks or stops.
- No visible effect: generation increased, but the tree and pixels did not change (finding 4 in section 5).

### Tool table

| Tool | How it works | What it gives the agent | Maintenance (2026-11-21) |
|---|---|---|---|
| `xcrun simctl` (Xcode 27.2) | CoreSimulator CLI | Screenshot (file or stdout), video, launch with console, `spawn log stream`, deep links, privacy, appearance, status bar | Apple, ships with Xcode |
| `xcrun devicectl` (Xcode 27.2) | CoreDevice CLI; lists simulators | Screenshot, screen record, Darwin notification post/observe | Apple; simulator use untested |
| Xcode MCP `DeviceInteraction*` via `xcrun mcpbridge` | XCTest remote automation inside Xcode (inferred) | Boot, run, tap/swipe/type, thumbnail + full screenshot, hierarchy with hit points, console log path | Apple, new in Xcode 27; external exposure not verified |
| Xcode MCP `RunProject`, `GetConsoleOutput`, `InvokeDebuggerCommand` | Xcode run and debug session | Run app, filtered logs, LLDB commands | Apple, Xcode 27 |
| idb (`meta/idb`) | `AccessibilityPlatformTranslation`, CoreSimulator XPC, in-guest `axbridge`, SimulatorKit Indigo HID, framebuffer IOSurface, `libShimulator` | Tree (3 backends), input, quiescence, framebuffer, code injection REPL | Very active; v1.7.8 (2026-11-01); MIT |
| AXe (`cameroncooke/AXe`) | Vendored idb frameworks | `describe-ui`, selector taps, `batch`, `serve`, agent mode with settled captures, screenshot, stream-video | Active; v2.1.1 (2026-11-19); GPL-3.0-only after v2.0.4 |
| MobileBuildMCP (ex XcodeBuildMCP) | Node MCP server; `simctl` + bundled AXe 1.8.0 | Build/run, screenshot (800 px JPEG), `snapshot_ui`, `wait_for_ui`, input, log capture, LLDB, Xcode IDE proxy | Active; v2.7.1 (2026-09-23); MIT; Sentry |
| ios-simulator-mcp | Node MCP server over idb | `ui_describe_all`, `ui_tap`, `ui_type`, `ui_view`, screenshot, video, `open_url` | Active; v2.2.1 (2026-11-10); MIT |
| sim-use (`lycorp-jp/sim-use`) | Static idb XCFrameworks + per-device daemon | Compact outline with `@N` aliases, alias taps, batch | Active; pushed 2026-11-19; Apache-2.0 |
| mobile-mcp / mobilecli | Go CLI with an XCUITest runner app (inferred from bundle ID) | Element list, screenshot with clip region, input | Active; 1.0.18 (2026-11-18); Apache-2.0 |
| simframe | Framebuffer IOSurface on damage + Vision OCR | ~20 ms frames, change detection in ~2 ms | Small; pushed 2026-10-05; 0 stars; MIT |
| LookinServer | In-app server on `127.0.0.1:47164-47169`; window and layer walk; per-layer render | Full UIKit/layer tree with images | Stale; last push 2024-07-17 |
| FLEX | In-app UI; view walk | Manual hierarchy and state inspection | Active; pushed 2026-10-18 |
| swift-snapshot-testing | `recursiveDescription`, `drawHierarchy`, `layer.render(in:)` | Reference code for in-process snapshots | Active; pushed 2026-10-21 |
| AccessibilitySnapshot | In-process accessibility parser with Codable export | Accessibility tree without XPC | Active; pushed 2026-11-11 |
| SwiftUI `_viewDebugData` | Underscored public API on `_UIHostingView`, gated by `SWIFTUI_VIEW_DEBUG` (inferred) | SwiftUI view types, values, frames as JSON | Present in iOS 27.2 SDK; undocumented |
| odiff / pixelmatch / ImageMagick | Pixel diff (SIMD / AA-aware / general) | Diff count, diff image, bounding box | odiff v4.5.0 (2026-07-23); pixelmatch pushed 2026-10-06; ImageMagick 7.1.2-10 local |

### Open questions

1. Does `xcrun mcpbridge` expose the `DeviceInteraction*` tools to external agents? Check with a `tools/list` call while Xcode is open. I did not run it, because connecting triggers Xcode's agent UI.
2. Does XCTest automation mode (used by Xcode's tools and by idb `axbridge`) interfere with hot-reloaded code, for example swizzles or accessibility caches that hold old view types?
3. What are `simctl io screenshot` latency and the cost of an in-app tree walk on Xcode 27.2 with an iOS 27.2 simulator on this Mac? Both need a booted simulator, which I did not start. No source measures the in-app walk.
4. Does `SWIFTUI_VIEW_DEBUG` work on the iOS 27.2 runtime, which bitmask values are valid, and what does it cost per frame? Only the string's presence in the 26.5 runtime is verified.
5. Does `simctl io <dev> poll` report display damage events? If yes, it is a public-CLI alternative to the private framebuffer callbacks.
6. Do `devicectl device notification observe` and `simctl spawn ... notifyutil -w` work against a simulator, and with what latency?
7. Local tool versions are behind: `idb_companion` 1.1.8 (2022), AXe 1.8.0, `xcodebuildmcp` 2.3.2. Which versions does the product depend on, and is AXe's GPL acceptable if the product bundles it?
8. Should the loop own the idle signal (dylib) or take it from XCTest quiescence (Xcode tools)? The dylib is faster and exact. XCTest needs no app changes.
