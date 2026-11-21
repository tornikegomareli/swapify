---
name: hotreload
description: Reload Swift edits into a running iOS Simulator app without a rebuild, then check the result with a screenshot, the visible text, and taps. Use when you change SwiftUI or Swift code of an iOS app and want to see or test the change in the simulator, or when a hotreload hook message appears after an edit.
---

# hotreload

`hotreload` patches edited Swift files into the running app in about one second. App state stays: the current screen, navigation, `@State`, models, and singletons.

## Start a session

Run these once per app launch, from the directory that holds the Xcode project.

1. `hotreload build --project App.xcodeproj --scheme App`. Use `--project App.xcworkspace` for a workspace.
2. Boot a simulator. Use Simulator.app or `xcrun simctl boot <udid>`.
3. `hotreload launch`. It installs the app and starts it with the in-app agent.

In this repository, run `swift build` first and call `.build/debug/hotreload`.

## After each edit

A PostToolUse hook reloads every `.swift` file you edit. Its message tells you one of three things:

- **Live.** The message gives the screenshot path and the visible text. Read the screenshot when the change is visual.
- **Does not compile.** The message lists the errors. The app still runs the previous code, so fix the errors.
- **Not applied, needs a rebuild.** Run `hotreload build ...` and `hotreload launch` again. App state resets.

Without the hook, run `hotreload reload <File.swift>` yourself. It returns the same result as JSON.

## Check behavior

- `hotreload ui` lists the visible accessibility elements top to bottom, with label, value, traits, and frame.
- `hotreload tap "<label>"` activates the element with that label. Run `hotreload ui` after it to see the result.
- `hotreload screenshot` captures the whole simulator screen, including system alerts.

## What needs a rebuild

- Adding, removing, renaming, or retyping a stored property.
- Adding a method to a non-final class.
- A new or deleted Swift file.
- Changes to resources, `Info.plist`, entitlements, or package dependencies.

These edits reload, but existing objects keep their old values:

- The initial value of a stored property or a `static let`.
- Code that ran once at launch, such as an `App.init`.
