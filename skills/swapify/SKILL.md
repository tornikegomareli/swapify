---
name: swapify
description: Patch Swift edits into the running iOS app, in the simulator or on an iPhone, in about a second, without a rebuild, then check them with a screenshot, the visible text, and taps. Use when you change Swift or SwiftUI code of an iOS app that has a swapify.json, or when a swapify message appears after an edit.
---

# swapify

swapify recompiles only the Swift files you edit and patches them into the running app, in the simulator or on an iPhone. App state stays: the current screen, navigation, `@State`, models, and singletons.

## Start

Run once per session, in the directory with `swapify.json`:

```sh
swapify run
```

It builds the app with reload support, boots a simulator if none is booted, and launches the app. If there is no `swapify.json`, run `swapify init` first. To work on the connected iPhone instead, run `swapify run --device`.

## After each edit

The Claude Code hook reloads every Swift file you edit and reports one of these:

- **Live.** The message gives a screenshot path and the visible text. Read the screenshot when the change is visual.
- **Does not compile.** The message lists the errors. The app still runs the previous code. Fix the errors.
- **Needs a rebuild.** The edit changed a type's layout. Run the command the message names: `swapify run`, or `swapify run --device` on an iPhone. App state resets.
- **Not part of the build.** The file is not in the app, and neither its folder nor a folder above it has an app file. A new file next to app files reloads like any other file.
- **The app did not answer.** It crashed, or it is in the background. Run `swapify run --no-build`.

Without the hook, call `swapify reload <File.swift>...`, or the `reload` MCP tool. Both return the same result.

## Check behavior

- `swapify ui` lists the visible accessibility elements, top to bottom, with traits and frames.
- `swapify tap "<label>"` activates the element with that label or accessibility identifier.
- `swapify screenshot` saves the app's screen. Add `--full` for the whole simulator screen, including system alerts.

The MCP tools `ui`, `tap`, and `screenshot` do the same, and `tap` returns the visible text after the tap.

## What needs a rebuild

- Adding, removing, renaming, or retyping a stored property of a type that existed at the last build. Types you created since then may change.
- Adding or removing a method of a non-final class.
- A deleted file.
- Resources, `Info.plist`, entitlements, or package dependencies.

These reload, but objects that exist keep their old values:

- The initial value of a stored property.
- Code that ran once at launch, such as `App.init`.

A changed initial value of a `static let` or a global constant keeps its old value, even if nothing read it before the reload: the app computes it once, with the code it was built with. A computed property (`static var x: T { … }`) reloads. If the screen still shows an old constant, make it a computed property, or run `swapify run`.

Each reload compiles every file changed since the last build, in parallel. A large file with many macros can take several seconds.
