# Spike 06: stored properties added to an existing class, in a side table

Question: can a patch add a stored property to a class the app was built with, without a rebuild?

Answer: yes for a `final` class, plain or `@Observable`. Not yet for a non-final class: a new field shifts the class's vtable, and the IR does not say which class a vtable slot belongs to. Measured on macOS with `./run.sh` on 2026-11-26, Xcode 27.2.

## How it works

Existing objects keep their size and every offset. The new field lives outside the object, and only patch code knows it exists, so all of that code is rewritten to reach it through a side table.

1. **IR.** The file as it was built and the edited file compile to IR with the app's flags (`-Onone -enable-implicit-dynamic`).
2. **Rewrite** (`rewrite.py`). For each class in both modules whose layout changed, fields are matched by name through the field descriptors (`$s…MF`):
   - The class's LLVM type goes back to the built layout. Accesses to existing fields get their built element index.
   - Every access to a new field, `getelementptr inbounds %T…C, ptr %obj, i32 0, i32 N`, becomes a call to a generated helper that returns the field's address in side storage. In Swift's -Onone IR this one instruction is the only way code reaches a stored property of a final class: getter, setter, `modify`, initializer and methods all use it.
3. **Side storage** (`SWPSideField` in `runtime/runtime.m`). One block of memory per object and field, keyed by `"<type>.<field>"`, attached to the object as an associated object, so it is released with the object. Its size, alignment and destroy function come from the field type's value witnesses, through `swift_getTypeByMangledNameInContext` and the mangled name the field descriptor already holds.
4. **First values.** On an object made before the patch, the first access runs the property's initial-value function (`…vpfi`) into the storage. A designated initializer (`…fc`) stores the first value itself. `@Observable`'s backing field `_count` has no initial-value function of its own, so it uses `count`'s.
5. **Object code.** `clang -c -O0`, then a dylib, as device patches are built today.

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

`observable`: `@Observable final class Model { var a = 1 }` gets `var count = 5`.

| Check | Result |
|---|---|
| Object made before the patch reads `count` | `count=5` |
| `withObservationTracking` fires when the patch mutates `count` | yes |
| Object made after the patch | starts at 5 |
| Leaks at exit | 0 |

## Not solved

- **Non-final classes**, which include the default `@Observable class`. A non-final class reaches its stored properties through vtable slots, and class metadata puts the field offset vector before the vtable. So any new stored property shifts every slot. With `func describe()` in an `@Observable class`, its slot is 18 as built, 19 with a new `final var count`, and 25 with a new `var count`. In IR the dispatch is `load ptr, ptr %obj` then `getelementptr inbounds ptr, ptr %isa, i64 18`, and nothing ties the slot to a class. A way to try: also compile to SIL, where `class_method` names the class and the method, and match those to the IR's vtable loads, function by function, in order.
- **Structs.** A struct copy has no identity to key the storage on.
- **Property wrappers whose storage type differs from the property**, such as `@Published`. The initial-value function returns the wrapped value, not the wrapper.
- **Key paths to the new stored field itself.** Its `…Wvd` offset is the new layout's.
- **Device.** Not tried. The runtime would live in the signed device agent.

## What swapify would need

- Simulator patches compile straight to `.o`. This needs the IR route that device patches already take (`DevicePatches`), and copies of the built files for simulator builds too.
- The agent's layout guard (Agent/Layout.m) must accept a class whose only change is new fields the patch moved to side storage.
- `SWPSideField` in the agent.

## Files

- `run.sh [plain|observable]` builds and runs both cases.
- `rewrite.py` is the IR rewrite. `runtime/` is the side table and the stand-in for the agent.
- `<case>/app` is the app as built, `<case>/patch` the edited file.
