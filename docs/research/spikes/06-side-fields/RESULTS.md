# Spike 06: stored properties added to an existing class, in a side table

Question: can a patch add a stored property to a class the app was built with, without a rebuild?

Answer: yes, for final and non-final classes, plain or `@Observable`, and for a subclass defined in the same file. As a side effect, a new method on a non-final class reloads too, which swapify refuses today. Measured on macOS with `./run.sh` on 2026-11-26, Xcode 27.2. Not yet tried inside swapify or on a device.

## How it works

Existing objects keep their size and every offset. The new field lives outside the object, and only patch code knows it exists, so the patch's IR is rewritten in two places.

1. **IR and SIL.** The file as it was built compiles to IR. The edited file compiles to IR and to SIL. All use the app's flags (`-Onone -enable-implicit-dynamic`).
2. **Field accesses** (`rewrite.py`). For each class whose LLVM struct type changed, fields are matched by name and declaring class through the field descriptors (`$s…MF`), superclass fields first, as the struct lays them out:
   - The class's LLVM type goes back to the built layout. Accesses to existing fields get their built element index.
   - Every access to a new field, `getelementptr inbounds %T…C, ptr %obj, i32 0, i32 N`, becomes a call to a generated helper that returns the field's address in side storage. Getters, setters, `modify`, initializers and the methods of a final class all reach a stored property through this one instruction.
3. **Vtable calls** (`rewrite.py --sil`). A non-final class reaches its properties and methods through vtable slots, and class metadata puts the field offset vector before the vtable. So a new stored property moves every slot, and its accessors add slots of their own. In IR a call is `load ptr, ptr %obj` (the isa), `getelementptr inbounds ptr, ptr %isa, i64 <slot>`, then a load marked `!invariant.load`. Nothing there names the class, but SIL does: `class_method %0, #Counter.a!getter : <type>`. The rewrite matches the SIL calls to the IR loads in the same function, in order. Each member is its name plus its type, because overloads share a name (`@Observable` makes four `shouldNotifyObservers`). Then, for a class whose slots moved:
   - A call to an existing member gets the member's slot in the app's metadata, read from the built IR's full metadata (`$s…Mf`).
   - A call to a new member becomes a direct reference to the patch's implementation. No class the app was built with can override a member it has never seen. If a class in the patch overrides it, the rewrite stops.
   - The rewrite also stops if a function's count of SIL calls and IR loads differs, or if a load's slot is not the member's slot in the patch's metadata.
4. **Side storage** (`SWPSideField` in `runtime/runtime.m`). One block of memory per object and field, keyed by `"<declaring type>.<field>"`, attached to the object as an associated object, so it is released with the object. Its size, alignment and destroy function come from the field type's value witnesses, through `swift_getTypeByMangledNameInContext` and the mangled name the field descriptor already holds.
5. **First values.** On an object made before the patch, the first access runs the property's initial-value function (`…vpfi`) into the storage. A designated initializer (`…fc`) stores the first value itself. `@Observable`'s backing field `_count` has no initial-value function of its own, so it uses `count`'s.
6. **Object code.** `clang -c -O0`, then a dylib, as device patches are built today.

The app's deinit is not replaceable (`…Cfd` has no replacement prologue), so it never touches the new field. The side storage destroys it when the associated object is released.

The harness also stands in for two steps Agent/Patcher.m already does in the simulator: it copies the app's field offsets that are set at metadata initialization (`…Wvd`, here the observation registrar's), and it makes the patch's metadata accessor return the app's metadata (`--redirect-accessor`). Without the second one, the patch initializes its own copy of the class and overwrites the copied offset with the new layout's.

## Results

`plain`: `final class Counter { var a = 1 }` gets `var count = 5` and `var note = "<a string on the heap>"`.

| Check | Result |
|---|---|
| Object made before the patch reads the new fields | `count=5`, `note=…`, and `a=7` is kept |
| The patch's methods mutate them on that object | `count=7`, `note=…++` after two steps |
| Object made after the patch, by the app's `Counter()` | `count=5`, through the patched initializer |
| Two objects keep separate values | yes |
| Storage released with the object | 6 boxes, 4 after the third object is released |
| Leaks at exit (`leaks --atExit`) | 0 |

`nonfinal`: the same `Counter`, not final, with a final subclass `Special` (its own field `extra`) in the same file. The patch also adds a method, `doubled()`, which `describe()` calls. The rewrite moved 1 vtable call to the app's slot and made 6 direct.

| Check | Result |
|---|---|
| Object made before the patch | `count=5 doubled=10`, `a=7` kept |
| `Special` made before the patch, through an old call site typed `Counter` | `special(extra=10) … count=5`: its own field at its built offset, then the patched `super.describe()` |
| Steps through the old call site mutate the subclass object | `count=7 doubled=14` |
| `Special` made after the patch | `extra=9`, `count=5` before its step |
| Leaks at exit | 0 |
| Control: the same patch without `--sil` | the process crashes (exit 139) |

`observable`: `@Observable class Model { var a = 1 }`, not final, gets `var count = 5`. The rewrite moved 11 vtable calls to the app's slots and made 4 direct.

| Check | Result |
|---|---|
| Object made before the patch reads `count` | `count=5` |
| `withObservationTracking` fires when the patch mutates `count` | yes |
| Object made after the patch | starts at 5 |
| Leaks at exit | 0 |

## Not solved

- **Structs.** A struct copy has no identity to key the storage on.
- **Property wrappers whose storage type differs from the property**, such as `@Published`. The initial-value function returns the wrapped value, not the wrapper.
- **Key paths to the new stored field itself.** Its `…Wvd` offset is the new layout's. `@Observable` is not affected: its key paths name the computed property.
- **A new field after a field of resilient layout.** The struct type stops at the first resilient field, so a field after it is reached through an offset global, not the rewritten instruction. The rewrite refuses it. `@Observable` puts its registrar last, so its new fields come before it.
- **Subclasses in other files** of a class whose slots moved. Their full metadata is not in the patch's IR, so calls through their own slots are not rewritten.
- **Initial values returned indirectly** (`sret`, large types). The helper has the branch, but no case exercised it.
- **Cost.** The SIL is a second frontend run of the edited file. Not measured.
- **Device.** Not tried. The runtime would live in the signed device agent.

## What swapify would need

- Simulator patches compile straight to `.o`. This needs the IR route that device patches already take (`DevicePatches`), a SIL compile of each edited file, and copies of the built files for simulator builds too.
- The agent's layout guard (Agent/Layout.m) must accept a class whose only change is fields the patch moved to side storage, and new members the patch calls directly.
- `SWPSideField` in the agent.

## Files

- `run.sh [plain|nonfinal|observable]` builds and runs the cases.
- `rewrite.py` is the IR rewrite. `runtime/` is the side table and the stand-in for the agent.
- `<case>/app` is the app as built, `<case>/patch` the edited file.
