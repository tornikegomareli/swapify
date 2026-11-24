# Changelog

## 0.1.0 (2026-11-25)

The first release: hot reload for coding agents on iOS, in the simulator and on an iPhone.

### What it does

- `swapify run` builds a Debug app with reload support and launches it in the simulator. `swapify run --device` does the same on a connected iPhone, without a debugger.
- After an edit, `swapify reload`, or the Claude Code hook, compiles the Swift files changed since the build and loads them into the running app. The app keeps its screen, its navigation stack and its `@State`.
- New Swift files reload without a rebuild.
- After each reload the agent gets a screenshot and the visible text. `swapify ui`, `tap` and `screenshot` let it read and use the screen.
- If an edit does not compile, the app keeps running the last code that compiled, and the agent gets the compiler errors.
- If an edit changes the stored properties of a type the app was built with, or the methods of a class, nothing is loaded, and the agent is told which type changed and to run `swapify run`.
- `swapify init` adds a Claude Code hook and skill. `swapify mcp` offers the same steps to any MCP client (MCP 2026-07-28 and the earlier `initialize`-based versions).
- `swapify doctor` checks the Mac, Xcode, the project, the simulator or iPhone, and the running app.

### Install

```sh
brew tap tornikegomareli/swapify https://github.com/tornikegomareli/swapify
brew install swapify
```

### Requirements

- An Apple silicon Mac and Xcode 26 or later.
- An iOS 26 or later simulator, or an iPhone with iOS 26 or later, Developer Mode on, and a signing team in the project.
- Tested with Xcode 27.2 and iOS 27.2.

### Known limits

- Debug builds only.
- UIKit screens do not redraw by themselves; observe the `SwapifyDidReload` notification to rebuild one.
- The app must be in the foreground. On an iPhone, the phone must be unlocked.
- Device mode has been tested on one iPhone with iOS 27.2, over Wi-Fi.
