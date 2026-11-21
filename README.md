# hotreload

Live Swift reload into a running iOS Simulator app, built for coding agents. The agent edits a Swift file, the change is live in about half a second, and the agent gets a screenshot and the visible text back. App state stays.

Tested with Xcode 27.2 and the iOS 27.2 simulator on Apple silicon.

## Use

```sh
swift build                                   # builds .build/debug/hotreload
cd Examples/Showcase && xcodegen generate     # or any Xcode project of your own
../../.build/debug/hotreload build --project Showcase.xcodeproj --scheme Showcase
../../.build/debug/hotreload launch           # needs a booted simulator
# edit Showcase/TaskListView.swift, then:
../../.build/debug/hotreload reload Showcase/TaskListView.swift
```

`reload` prints JSON with the timings, the screenshot path, and the visible text. Other commands are `ui`, `tap <label>`, and `screenshot`. Run `hotreload` without arguments to see them.

The project needs no changes. `build` passes the required Debug settings to `xcodebuild`. `launch` also reloads one unchanged file, which pays the first-load cost before the first real edit.

A warm reload on Showcase measured 506–543 ms: compile 230 ms, link 210 ms, load and refresh 14–26 ms, then the snapshot and visible text.

## Test

`python3 -I scripts/e2e.py [--udid <UDID>]` runs the whole flow on Showcase against a booted simulator. It checks a visual edit, a compile error, a layout change, a model behavior change with a tap, and a new view type. It restores the example files afterwards.

## Claude Code

`.claude/settings.json` in this repository runs `hotreload hook` after every Edit or Write. If the edited file is Swift and its project has a session (`.hotreload/` next to it), the hook reloads the file. It returns the result to the model, which is one of: live with a screenshot and visible text, compile errors, or "needs a rebuild".

`skills/hotreload/SKILL.md` tells the agent how to start a session, check behavior, and when to rebuild.

## How it works

1. **Build.** The app is built with `-enable-implicit-dynamic`. Every Swift function then starts with a check of its dynamic replacement chain root (`$s...TX`). `EMIT_FRONTEND_COMMAND_LINES=YES` puts each file's exact compile command in the build log.
2. **Agent.** `agent/HotAgent.m` is inserted at launch with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. It listens on `127.0.0.1:8899`.
3. **Reload.**
   1. The CLI compiles the edited file unchanged with its original command.
   2. It links the object into a dylib.
   3. The agent `dlopen`s the dylib.
4. **Patch, new to old.** The patch defines its own copy of every type and static in the file. The agent replaces the start of each new metadata accessor and addressor with a jump to the app's original. It also copies the field offsets, so new code uses the app's types, objects, and storage.
5. **Patch, old to new.** The agent copies each new chain root into the app's root, so old callers run the new bodies.
6. **Refresh.** The agent invalidates every SwiftUI view graph, as `AppPreviewHost.invalidateEverything()` does. It skips `incrementPhase()`, which would reset `@State`.
7. **Safety.** Before patching, the agent compares each type's nominal descriptor in the patch with the app's descriptor. If stored properties or a class vtable changed, it patches nothing and reports `needsRebuild`.

Background and sources: `docs/research/ios-simulator-hot-reload.md`. Experiments: `spikes/`.

## Limits

- **Reload time is that file's compile time.** On a real TCA app, a 495-line reducer file took 9.6 s to compile alone, while a view file took 0.4 s.
- **The app must be in the foreground.** iOS suspends background apps, so the agent cannot answer. After 10 s the CLI reports this instead of hanging.
- **SwiftUI refresh only.** In UIKit code, methods get the new bodies, but nothing calls `viewDidLoad` again. The change shows the next time that code runs. This follows from the mechanism and is untested.
- **Simulator only.** The agent writes jumps into the patch's code pages, which a device does not allow.
- **Debug builds only.** `-enable-implicit-dynamic` makes calls slower.
- **Needs a rebuild:**
  - A stored property is added, removed, renamed, or retyped.
  - A method is added to a non-final class.
  - A file is added or deleted.
  - Resources, `Info.plist`, or dependencies change.
- **Uses private SwiftUI symbols.** The refresh calls `GraphHost`, `_UIHostingView.viewGraph`, and `AGGraphInvalidateAllValues` by their mangled names. A future iOS version can rename them. If that happens, the refresh fails, but the reload still applies.
- **Turns on accessibility.** `ui` and `tap` turn on application accessibility in the simulator.
