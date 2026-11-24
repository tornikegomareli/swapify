# Spike 04: binding a patch to the app through dyld, on a device

Question: can a Swift patch run on the device with no debugger and no code writes? The idea is to bind the patch to the app's own symbols when it loads, instead of writing 16-byte jumps into the patch's accessors (docs/architecture.md, section 5).

Answer: yes. On "Doomile" (iPhone19,4, iOS 27.2, build 24B91020), the test ran without a debugger (`P_TRACED=0`, `CS_DEBUGGED=0`, `cs_flags=0x22003305`, so `CS_KILL` and `CS_HARD` are set). Two patches of two files loaded one after the other, and all 57 checks passed. The only writes are the chain roots in the app's `__DATA,__data`. Measured on 2026-11-24 with Xcode 27.2 (27B52), over Wi-Fi.

## What the app build needs

| App flags | Symbols the patch imports that the app exports |
|---|---|
| `-enable-implicit-dynamic -enable-testing -enable-private-imports` (this spike) | 16 of 16 |
| without `-enable-private-imports` | 14 of 16. The `private` type's metadata and addressor are local (`non-external`) |
| without `-enable-testing` | 16 of 16 |
| neither | 0 of 16. Internal symbols are `private external` (hidden), private ones local |

`python3 -I flags.py` measured this by compiling both edited files with the build's own command per variant. The 16 imports are those of the two-file patch. `-enable-private-imports` covers both internal and private declarations. `-enable-testing`, which Xcode turns on in Debug through `ENABLE_TESTABILITY`, misses private ones. Xcode's link used `-dead_strip` and no export list, and still exported everything. `-export_dynamic` is not needed.

With both flags, the app exports every kind the patch needs from `Model.swift` (`exports.py`): 5 metadata accessors, 3 addressors, 2 field offsets, 2 witness tables, 22 chain roots, 5 type descriptors, 5 type metadata symbols, and 2 conformance descriptors. The private type's are included. Only the lazy-init tokens (`$s…Wz`) are hidden, and the patch does not need them, because it calls the app's addressors.

## The patch pipeline

`patch.py <version>` handles each file in `edits/<version>/` and links one dylib:

1. **IR.** It takes the build's own `swift-frontend -frontend -c` command for that file from `build/build.log`, as swapify does. It applies swapify's `FrontendCommand.patch` rewrite, uses `-emit-ir` instead of `-c`, and drops `-g`. The edited file can live at another path: the private discriminator depends only on the basename (`Secret33_B706AEC…` in both builds).
2. **Rewrite.** `rewrite_ir.py` changes the IR in three ways:
   - Every global or alias the app exports becomes an `external` declaration, except chain roots (`TX`) and replacement keys (`Tx`). So does every accessor function (`Ma`, `vau`, `Wl`, `Wa`) the app exports.
   - Code that names a type's metadata as a constant `getelementptr` into the patch's own full metadata (`$s…Mf`) gets the imported `$s…N` instead. Every reference to a struct's metadata from new code looks like this. Without the fix, new code used a copy of `Item`'s metadata.
   - Function bodies and chain roots are kept, with whatever they reference. Everything else drops out: the patch's metadata, and the records that would register it (`__swift5_types`, `__swift5_proto`, `__swift5_fieldmd`, `__objc_classlist`). A direct symbolic reference to an imported type descriptor becomes an indirect one through a `got.` slot. That happened twice, in `ProbeView.swift`.
3. **clang.** `xcrun clang -c -O0` compiles the rewritten IR.
4. **Link.** `clang -dynamiclib -undefined dynamic_lookup`, as swapify links simulator patches.
5. **Codesign** with the certificate that signed the app (spike 03: a dylib signed by the same team loads from the data container).

The patch defines no type entity of the app's (`nm`: 0 definitions of `Mn`, `Mf`, `N`, `WP`, `Mc`, `Wvd`, `Ma`, `vau`, `vp`). Linking the same objects with `-bundle -bundle_loader Bind` succeeds, and `dyld_info -fixups` shows 16 binds to `<main-executable>`. So every import exists among the app's exports, and the link step proves it.

## Checks on the device (no debugger, `--test bind`)

`Driver.swift` is never reloaded, so its calls are the old call sites. A "current code" check calls a function in an edited file, so after a reload it runs new code. The app loads `patch_v2`, runs every check, then loads `patch_v3` and runs them again.

| Check | v1 (app) | v2 | v3 |
|---|---|---|---|
| `version()` | v1 | v2 | v3 |
| Old `Box.describe()` through the vtable | v1 box 7 | v2 box 7 | v3 box 7 |
| `Item.greet()` through the witness table | v1 hello x | v2 hello x | v3 hello x |
| Old `Box.greet()` through the witness table | v1 box 7 greets | v2 box 7 greets | v3 box 7 greets |
| `compute(3)`, which calls a `fileprivate` helper | 7 | 301 | 3001 |
| A closure made by v1 code calling `helper(5)` | 10 | 500 | 5000 |
| `secretText()`: `private` type and its `static let` (the edit changes the initializer to `salt-v2`) | v1 abc+salt1 | v2 abc+salt1 | v3 abc+salt1 |
| `Box` made by current code has the app's class (`ObjectIdentifier`) | true | true | true |
| Its `describe()`, which reads `value` through the field offset `$s…Wvd` | v1 box 9 | v2 box 9 | v3 box 9 |
| `Box` and `Item` metadata seen by current code is the app's | true, true | true, true | true, true |
| `private Secret` boxed by current code has the app's type | true | true | true |
| `static let token` read by current code is the app's instance | true | true | true |
| `static var hits` read by current code (app increments) | 1 (app 1) | 2 (app 2) | 3 (app 3) |
| `Item` boxed by current code `as? Greeter`; `Box` from current code `as? Greeter` | true, true | true, true | true, true |
| Existential made by current code, `greet()` | v1 hello w | v2 hello w | v3 hello w |
| `[Item]` built by current code | v1 hello a, b | v2 hello a, b | v3 hello a, b |
| `ProbeView.swift`: key path `\Box.value`, generic `Probe<T>`, SwiftUI `body` (gains `.padding()` and `.overlay` in v2) | v1 4 Probe<Int> body: DebugReplaceableView | v2 … | v3 … |

The loader reads every pointer slot of a loaded patch (`__got` and `__la_symbol_ptr`) by name. In each of the two patches, 103 slots name Swift symbols. 16 of them hold exactly the app's own address for that name, and 87 point into the Swift runtime, the SDK, or SwiftUI. A patch with only `Model.swift` had 25 slots, 9 of them pointing at the app.

The second patch replaced the first: 33 roots were written into the app and 33 into `patch_v2`. Then every v3 line above appeared.

**Writes.** Nothing in this test writes code, and nothing writes into `__DATA_CONST`. The only writes are the chain roots in the app's and the earlier patch's `__DATA,__data`. For the record (`--test dataconst`): `mprotect(RW)` on one of the app's `__DATA_CONST` pages returns 0 and a write succeeds. `vm_protect(RW|COPY)` on it returns `KERN_SUCCESS` and a write succeeds.

## Timings

Patch build on the Mac, warm, 3 runs, M4 Max:

| Step | 1 file (`Model.swift`) | 2 files (`Model.swift`, `ProbeView.swift`) |
|---|---|---|
| Compile to IR | 77 ms | 228 to 232 ms |
| Rewrite IR (Python) | 47 ms | 97 to 99 ms |
| clang `-c` | 18 ms | 45 to 46 ms |
| Link | 130 ms | 127 to 131 ms |
| Codesign | 42 ms | 42 to 50 ms |
| Total | 296 to 376 ms | 548 to 551 ms |

On the very first run, clang took 561 ms and the IR compile 160 ms. The two-file dylib is 135 KB, the one-file dylib 94 KB.

On the device:

| Step | Time |
|---|---|
| `devicectl device copy to` of the 94 KB patch | 1024 to 1100 ms. TCP to the app moved 100 KB in 21 to 46 ms in spike 03 |
| `dlopen`, first patch in a process | 0.9 to 13.4 ms; once 355 ms, on the first run after install |
| `dlopen`, second patch | 0.3 to 4.9 ms |
| `dlopen` of patches with new code hashes | 10.5 ms and 4.8 ms |
| Copy chain roots (data writes) | 0.05 to 0.16 ms |

With a TCP transfer through an in-app agent, one warm reload of one file would take about 300 ms + 40 ms + 10 ms. That estimate adds measured steps; the whole sequence was not timed in one run.

## Not tested, or known gaps

- **Layout guard.** The patch imports the app's type descriptors and has no `Mn` of its own, so swapify's on-device guard has nothing to compare. A guard has to run on the Mac, comparing the patch IR's descriptors before the rewrite with the app build's.
- **New types and conformances in an edit.** The app does not export them, so the rewriter keeps the patch's definitions. But it drops their `__swift5_types` and `__swift5_proto` records, because only code is a root. Name lookups and `as?` casts to a new conformance would fail. The fix is to keep the records whose target stays defined in the patch. Not tried.
- **Debug info.** The IR step drops `-g`, so LLDB has no source lines for patch code. Keeping `-g` needs the rewriter to remove the debug records of definitions it turns into declarations.
- **Xcode's default debug dylib.** This app set `ENABLE_DEBUG_DYLIB=NO`. With Xcode's default, exports live in `Bind.debug.dylib`. Flat-namespace binding should find them there, but this was not tested.
- **SwiftUI rendering and the refresh.** `body` ran and returned the new view value, but nothing redrew a live view.
- **Not in the edited files:** stored-property layout changes, `@objc` members, generic functions specialized across files, `@inlinable` code, and arm64e.

## Problems seen

- An incremental Xcode build writes no frontend command for files it did not recompile, so `build.sh` does `clean build`. swapify does a full build at launch.
- `devicectl` once printed "The process identifier of the launched application could not be determined" for a launch that had already finished and printed its output.

## Files

- `project.yml`: app `Bind`, bundle ID `dev.swapify.spike.device`, swapify's Debug settings plus `-enable-private-imports`, `ENABLE_TESTABILITY=YES`, `ENABLE_DEBUG_DYLIB=NO`.
- `App/Model.swift`, `App/ProbeView.swift`: the edited files; `edits/v2/`, `edits/v3/` hold their new versions. `App/Driver.swift`: the old call sites and the checks. `App/Loader.c`: `dlopen`, the pointer-slot report, chain-root copying, and the `__DATA_CONST` probe.
- `patch.py`: the pipeline. `rewrite_ir.py`: the IR rewrite. `exports.py` and `flags.py`: export checks.
- `build.sh` builds the app and both patches. `run.sh` installs, copies the patches, runs `--test bind` and `--test dataconst`, and uninstalls. The phone must be unlocked. Logs go to `build/logs/`.
