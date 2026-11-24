# Architecture

swapify makes Swift edits live in a running iOS Simulator app. This document describes each step and the Swift ABI structures it touches. Symbol names, offsets, and measurements are from Xcode 27.2, Swift 6.4, and the iOS 27.2 simulator on Apple silicon.

```text
 host (swapify CLI / MCP server)                         simulator app process
 ─────────────────────────────────                       ──────────────────────────────────────
 Edit TaskListView.swift
   │
   ├─ swift-frontend -c -primary-file TaskListView.swift   (the build's own command)
   ├─ clang -dynamiclib -undefined dynamic_lookup
   │
   └─ "load /…/patch.dylib" ──── 127.0.0.1:port ────▶  SwapifyAgent
                                                           ├─ dlopen
                                                           ├─ layout guard  ($s…Mn)
                                                           ├─ new → old     ($s…Ma $s…vau $s…Wl $s…Wa
                                                           │                 $s…Wvd $s…WP)
                                                           ├─ old → new     ($s…TX chain roots)
     "refresh" ───────────────────────────────────────▶   ├─ AGGraphInvalidateAllValues per view graph
     "snapshot" / "ui" ───────────────────────────────▶   └─ drawViewHierarchy, accessibility tree
```

## 1. Build

`swapify run` builds the app's Debug configuration into `.swapify/DerivedData` and passes four settings on the `xcodebuild` command line. The project is not changed.

| Setting | Why |
|---|---|
| `OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic` | Makes every Swift function dynamically replaceable (section 4). |
| `EMIT_FRONTEND_COMMAND_LINES=YES` | Prints each `swift-frontend -frontend -c …` job into the build log. swapify maps every `-primary-file` to its command. |
| `COMPILATION_CACHE_ENABLE_CACHING=NO` | Cached builds pass `llvmcas://` inputs that a single-file compile cannot read. |
| `ARCHS=arm64` | One slice: the simulator runs the host architecture. |

With `-enable-implicit-dynamic`, each function gets a prologue. This is the IR for a free function `report(_:)` at `-Onone`:

```llvm
@"$s3App6reportyySSFTX" = global %swift.dyn_repl_link_entry { ptr @"$s3App6reportyySSF", ptr null }

define swiftcc void @"$s3App6reportyySSF"(i64 %0, ptr %1) {
entry:
  %8 = call ptr @swift_getFunctionReplacement(ptr @"$s3App6reportyySSFTX", ptr @"$s3App6reportyySSF")
  %9 = icmp eq ptr %8, null
  br i1 %9, label %original_entry, label %forward_to_replaced
forward_to_replaced:
  tail call swiftcc void %8(i64 %0, ptr %1)
  ret void
original_entry:
  ; the function body
```

`swift_getFunctionReplacement(root, self)` returns null when `root->implementationFunction == self`, and the function runs its own body. Otherwise it returns the stored pointer, and the function tail-calls it (`stdlib/public/runtime/FunctionReplacement.cpp`). The chain root `$s…TX` is a `{ implementationFunction, next }` pair in writable `__DATA,__data`. Roots exist for local and `private` symbols too.

The same flag makes the type checker wrap every opaque `body` result in SwiftUI's `DebugReplaceableView` type eraser. A reloaded `body` can therefore return a different view type without breaking callers that cached the opaque type's metadata.

The cost is one runtime call per function call: 7% in a call-heavy micro benchmark at `-Onone`, and no inlining at `-O`. swapify uses Debug builds only.

## 2. Patch build

`swapify reload File.swift` compiles every file changed since the last build: the files reloaded since then and the new files (section 11). Each compile rewrites the build's own frontend command for its file (`FrontendCommand.patch`), and they run in parallel:

- The file stays the only `-primary-file`. Other primary files of the same batch job become plain inputs.
- `-o`, `-emit-*-path`, `-serialize-diagnostics-path`, `-index-*`, and the supplementary output file map are dropped, and a new `-o` is added.
- The file keeps its path. The mangled name of a `private` declaration contains a discriminator derived from the file name, so the patch's `private` symbols match the app's.

The objects are linked into one dylib with the clang next to `swift-frontend`, as `-dynamiclib -undefined dynamic_lookup`. References to the rest of the app stay undefined and bind to the running process at `dlopen`. The linker signs the dylib ad hoc, which the simulator accepts. Every attempt gets a new directory, because `dlopen` of a path that is already loaded returns the old image.

Measured on a SwiftUI view file: compile 230 ms, link 210 ms.

## 3. The agent

`SwapifyAgent.dylib` is inserted at launch with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. `simctl` passes `SIMCTL_CHILD_*` variables into the app without the prefix. The agent's constructor:

1. Reads the symbol table of every image in the app bundle directory, local symbols included. Xcode 16 and later builds Debug apps as a stub executable plus `<App>.debug.dylib`, and both are in that directory.
2. Starts a thread that serves the line protocol ([protocol.md](protocol.md)) on `127.0.0.1:$SWAPIFY_PORT`. The CLI picks a free port per launch. Simulator apps share the host's network stack.

On `load <path>` the agent runs `dlopen`, then sections 4 to 6 in order, before any patch code can run.

## 4. Old callers run new code

For each chain root `$s…TX` in the patch whose function the app has, the agent finds the root with the same name in the app and in every earlier patch, and copies the patch root's `implementationFunction` into it. From then on, every entry into the old function forwards to the new body:

- direct calls and calls through the GOT;
- class vtable dispatch, because the vtable points at the old function, whose prologue forwards;
- protocol witness thunks, which call the concrete function;
- `private` functions, because their roots are in the symbol table.

The new function reads its own root, which still points at itself, so it runs its body. A second patch updates the app's roots and the first patch's roots.

A function that only patches define, one of a type that is new since the build, is not forwarded: each patch keeps its own copy (section 11).

## 5. New code keeps old types

The patch is a compilation of the whole file, so it defines its own copy of every type, static, and conformance in it. Left alone, the new code would allocate instances of a second `TaskModel` class, read a second copy of every `static let`, and show SwiftUI a second `TaskRow` type. SwiftUI would then rebuild that subtree and drop its `@State`, and `as?` casts between old and new instances would fail.

So the patch is pointed back at the app:

| Patch symbol | Action | Effect |
|---|---|---|
| `$s…Ma` type metadata accessor | Overwritten with `ldr x16, #8; br x16; .quad <app accessor>` | New code and mangled-name lookups get the app's metadata |
| `$s…vau` global and static addressor | Same jump | New code uses the app's storage for globals and `static` properties |
| `$s…Wl`, `$s…Wa` witness table accessors | Same jump | New code gets the app's conformances |
| `$s…Wvd` field offset | Copied from the app | Field offsets of types whose layout depends on resilient types are set when the metadata initializes. The patch's metadata never initializes. |
| `$s…WP` protocol witness table | Copied word by word from the app | The table names the app's conformance descriptor. Its function entries are the app's witness thunks, which reach the new code through section 4. |

A witness table has one word for the conformance descriptor and one per protocol requirement. The agent reads `NumRequirements` at offset 16 of the protocol descriptor that the conformance's relative indirectable pointer names.

The jumps are written to a private copy of the code page (`vm_protect` with `VM_PROT_COPY`), then the page is made executable again and the instruction cache is flushed. Simulator processes are ad hoc signed and not hardened, so this is allowed. A device does not allow it.

dyld never unloads an image that contains Swift or Objective-C, so each reload stays mapped: 65 KB for a small view file, 1.5 MB for a large reducer file. The Objective-C runtime logs `Class … is implemented in both`, which is expected.

## 6. The layout guard

New code runs on objects with the old layout, so a patch must not change stored properties or a class vtable. Before section 5, the agent compares every nominal type descriptor `$s…Mn` in the patch with the app's, following `swift/ABI/Metadata.h`:

- Classes (kind 16): `NumImmediateMembers` at offset 32 (vtable entries), metadata bounds, field count, and field offset vector offset.
- Structs (17) and enums (18): field count and field offset vector offset, or payload and empty case counts.
- Every field record: name, `let` or `var`, and mangled type name. Symbolic references in a type name point into different images, so they compare by the referenced descriptor's name. A direct reference (`0x01`) and an indirect one (`0x02`) to the same type are equal: the linker chooses one or the other.

If anything differs, the agent patches nothing and replies `needsRebuild` with the type and the reason. The loaded dylib stays inert, because nothing points at its code.

## 7. SwiftUI redraw

Replacing a `body` does not tell SwiftUI to evaluate it again. `SwiftUI.AppPreviewHost.invalidateEverything()`, which Xcode Previews uses, does this inside the graph host's update group:

```text
GraphHost.incrementPhase()
AGGraphInvalidateAllValues(GraphHost.graph)
GraphHost.emptyTransaction(Transaction())
GraphHost.flushTransactions()
```

The agent repeats this for every `_UIHostingView` in the app's windows, but skips `incrementPhase()`. A new view phase is what resets `@State`. It also calls `DebugReplaceableView.invalidateEverything()`, which only clears the lazy container cache. All functions are exported from SwiftUI, SwiftUICore, and AttributeGraph. The agent calls them through `dlsym` with Swift's calling convention. Clang's `swiftcall` attribute with a `swift_context` parameter puts `self` in `x20`. A full refresh takes 2 to 30 ms.

If a future iOS renames these functions, `ping` reports `"swiftUIRefresh": false`, reloads still apply, and views redraw on their next state change.

The agent also posts `SwapifyDidReload` with the generation in `userInfo`, and `INJECTION_BUNDLE_NOTIFICATION`, which keeps Inject's `@ObserveInjection` working.

## 8. Verification

After a reload the CLI asks the agent for two things:

- **Snapshot.** The agent renders the foreground windows with `drawViewHierarchyInRect:afterScreenUpdates:YES` at 1x. This applies pending updates first, so no delay is needed after the refresh. It takes about 46 ms and gives a 402 × 874 PNG, about 480 image tokens for a model.
- **Visible text.** SwiftUI builds its accessibility tree only while accessibility is on, so the agent calls `_AXSApplicationAccessibilitySetEnabled(1)` once, then walks the accessibility containers of every window. Elements are sorted by frame, because tree order can lag behind the screen. `tap` calls `accessibilityActivate` on the element whose label or identifier matches.

## 9. Timings

Warm reload of a SwiftUI view file on an M-series Mac with Xcode 27.2:

| Step | Time |
|---|---|
| Compile one file | 230 ms (a 495-line TCA reducer: 9.6 s) |
| Link | 210 ms |
| `dlopen` and patch | 3 to 14 ms (the first patch of a process: about 800 ms) |
| SwiftUI refresh | 2 to 30 ms |
| Snapshot and visible text | about 60 ms |
| Total | 506 to 543 ms |

`swapify run` reloads one unchanged file right after launch, so the agent's first real edit does not pay the cold `dlopen` cost.

## 10. On a device

`swapify run --device` runs the same loop against an app on a connected iPhone, with no debugger attached. Three things differ, because iOS on a device does not let a process write or create code pages, and the app is on another machine. [docs/research/spikes](research/spikes) has the measurements behind each choice.

**Build and launch.** The device build adds `-Xfrontend -enable-private-imports` to the reload settings, so the app exports every declaration, `private` ones included, and uses the project's own signing. After the build, the CLI records what the app's images export (`dyld_info -exports`, the debug dylib included) and copies each reloadable file into `.swapify/originals/`. At launch it signs the device agent with the identity that signed the app, copies it into the app's `tmp/` with `devicectl device copy to`, and launches the app with `DYLD_INSERT_LIBRARIES`, `SWAPIFY_PORT`, and a new `SWAPIFY_TOKEN`. iOS loads a library from the app's data container if the app's own team signed it. A `devicectl … --console` stays attached to the app, detached from the terminal: it writes the app's output to `.swapify/console.log` and holds the CoreDevice tunnel open, which closes within seconds without a client.

**Binding instead of jumps.** A device patch is compiled to LLVM IR with the build's own command, and `PatchBinder` rewrites it before clang compiles it. Every symbol the app exports, except chain roots, becomes an external declaration: type metadata, type and conformance descriptors, witness tables, field offsets, static storage, and the accessors and addressors. Code that names a type's metadata directly gets the app's `$s…N` instead. The patch keeps only the new bodies, its chain roots, and what they use, plus the types and conformances that are new in the edit. dyld binds the rest to the app when the agent `dlopen`s the patch, so section 5 needs no jumps and no copies: the agent only copies chain roots, which are data. The CLI signs each patch with the app's identity and sends its bytes over the socket (`put`), since the app cannot read the Mac's files.

**The layout guard runs on the Mac.** A bound patch has no type descriptors of its own, so the agent cannot compare layouts. Before anything is sent, `LayoutGuard` compares the IR of the file as it was built (compiled once from its copy) with the IR of the edit: for each type both define, the field records (name, `let` or `var`, type) and the type descriptor, which holds a class's vtable. It gives the same `needsRebuild` report as the agent on the simulator.

**The connection.** The agent listens on every interface of the device, and the CLI connects to the device's CoreDevice tunnel address, an encrypted link over the cable or the network, never the Wi-Fi address. Every connection must first send `auth <token>` within 2 s. The token is 128 random bits per launch, kept in `.swapify/session.json` with mode 0600. The CLI reads the tunnel address at launch, and reads it again once if a connection fails. A device app answers only while it is in the foreground and the phone's screen is on, so the device agent keeps the screen on while the swapify-launched app runs (`idleTimerDisabled`); locking the phone by hand still works.

## 11. New files

A Swift file that the build did not compile has no frontend command of its own. On its first reload it borrows the command of the nearest file that the build compiled: a file in the same folder, else in the nearest parent folder, up to the directory with `swapify.json`. `.swapify/session.json` keeps the record (`borrowed`). The new file is added to that command's inputs and compiled as the primary file. A command with a `-filelist` gets a copy of the list with the new file in the patch directory, because the frontend refuses file inputs next to a file list. From then on, every patch compile in that module gets the module's new files as inputs, so the files the build compiled can use the new types.

The app has none of a new file's types, so they need different rules from the app's own types:

- **The changed set.** Every patch compiles every file changed since the last build: each file reloaded since then (`changed`), and each new file. A type that is new since the build can only be used by these files, so the code that creates such a type and the code that reads it always come from the same patch, and they agree on its layout. Its stored properties may change from one patch to the next.
- **No jumps, no forwarding, no guard.** The agent finds no metadata accessor, field offset, or witness table of such a type in the app, so section 5 leaves the patch's own copy alone. Section 4 does not forward an earlier patch's copy of its functions to the new patch. Forwarding ran new code on values that an earlier patch had laid out, which showed wrong values or crashed. The layout guard compares only types the app has.
- **On a device**, a new file has no copy in `.swapify/originals/`, so the Mac's layout guard skips it. The bound patch keeps the new types' definitions, because the app does not export them.

`swapify run` builds the project again and clears the changed set. A synchronized folder adds the new files to the target, and they get commands of their own. With classic groups the build does not compile a new file, and `swapify run` prints `X.swift is not in the target; add it in Xcode.` swapify does not edit the project.

Measured with Examples/Showcase on a 14-core Apple silicon Mac: a reload of `TaskListView.swift`, with small new view files in the changed set. Each value is the median of 5 reloads, from two runs.

| Changed files | Edit to verified screen |
|---|---|
| 1 | 494 and 510 ms |
| 3 | 437 and 449 ms |
| 6 | 445 and 448 ms |
