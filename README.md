# swapify

**Agentic hot reload for iOS apps.** Your coding agent edits a Swift file. swapify recompiles that one file, patches it into the app that is running in the iOS Simulator, redraws SwiftUI, and returns a screenshot and the visible text to the agent. It takes about half a second. The app is not rebuilt or relaunched, and its state stays: the current screen, navigation, `@State`, models, and singletons.

```text
$ swapify reload Sources/Tasks/TaskListView.swift
✓ live TaskListView.swift  generation 3
  compile 230 ms · link 210 ms · patch 14 ms · refresh 5 ms · total 512 ms
  screenshot .swapify/screens/reload-3.png
  visible    Today | 2 of 3 done | Write the agent | Patch chain roots | 1 left
```

An agent iterates on design and behavior at the speed of an edit, and checks every step itself.

## Install

```sh
brew tap tornikegomareli/swapify https://github.com/tornikegomareli/swapify
brew install --HEAD swapify
```

Or from source: `make install PREFIX=/usr/local`.

You need an Apple silicon Mac, Xcode 26 or later, and an iOS 26 or later simulator. swapify is tested with Xcode 27.2 and iOS 27.2.

## Quick start

```sh
cd MyApp                 # the directory with your .xcodeproj or .xcworkspace
swapify init             # writes swapify.json, the Claude Code hook, the skill, and .mcp.json
swapify run              # Debug build with reload support, boots a simulator, launches the app
```

Edit a Swift file, then:

```sh
swapify reload MyApp/Views/HomeView.swift
```

Your Xcode project does not change. `swapify run` passes the build settings it needs to `xcodebuild` and keeps its own DerivedData in `.swapify/`.

## Agents

**Claude Code.** `swapify init` installs a PostToolUse hook. After every `Edit` or `Write` of a Swift file, the hook reloads it and gives the result to the model: live with a screenshot path and the visible text, compile errors, or "needs a rebuild". It also installs a skill that explains the workflow, and registers the MCP server in `.mcp.json`.

**Codex, Cursor, and other MCP clients.** Run the MCP server over stdio:

```sh
codex mcp add swapify -- swapify mcp
claude mcp add swapify -- swapify mcp
```

| Tool | What it does |
|---|---|
| `reload` | Patches edited files into the app; returns a summary, a screenshot, and the visible text |
| `ui` | Lists visible accessibility elements with traits and frames |
| `tap` | Activates an element by label or identifier; returns the visible text after the tap |
| `screenshot` | The app's screen, or the whole simulator screen with `full` |
| `run` | Builds and launches the app |
| `status` | Checks Xcode, the project, the build, the simulator, and the app |

The server speaks MCP 2026-07-28 (stateless, per-request `_meta`) and the earlier `initialize`-based versions. See [docs/agents.md](docs/agents.md).

## Commands

| Command | |
|---|---|
| `swapify init` | Set up the project: `swapify.json`, `.gitignore`, the Claude Code hook, skill, and MCP server |
| `swapify run` | Build with reload support and launch in the simulator (`--no-build` relaunches) |
| `swapify reload <files>` | Patch edited Swift files into the running app |
| `swapify ui` | List visible accessibility elements |
| `swapify tap <label>` | Activate an element by accessibility label or identifier |
| `swapify screenshot` | Save the app's screen (`--full` for the whole simulator) |
| `swapify doctor` | Check the Mac, Xcode, the project, the build, the simulator, and the app |
| `swapify mcp` | Serve the tools over MCP on stdio |

`run`, `reload`, `ui`, and `doctor` accept `--json`.

## How it works

1. **Build.** `swapify run` builds Debug with `-enable-implicit-dynamic`. Every Swift function then starts by reading its dynamic replacement chain root (`$s…TX`). `EMIT_FRONTEND_COMMAND_LINES=YES` records the exact compile command of each file.
2. **Agent.** A small dylib is inserted into the app at launch with `DYLD_INSERT_LIBRARIES`. It listens on a loopback port.
3. **Patch.** `swapify reload` compiles the edited file unchanged, with its own command, and links it into a dylib. The agent `dlopen`s it.
4. **New code, old types.** The patch carries its own copy of every type in the file. The agent points the patch's metadata accessors, addressors, field offsets, and witness tables at the app's originals, so new code uses the existing types, objects, and storage.
5. **Old callers, new code.** The agent copies each new chain root into the app's root, so every caller of an edited function runs the new body: direct calls, vtable dispatch, and protocol witnesses.
6. **Redraw.** The agent invalidates every SwiftUI view graph the way Xcode Previews does, without resetting `@State`.
7. **Guard.** Before patching, the agent compares each type's layout with the app's. If stored properties or a class vtable changed, it patches nothing and asks for a rebuild.

The details, with the Swift ABI structures involved, are in [docs/architecture.md](docs/architecture.md). The research behind it is in [docs/research](docs/research/ios-simulator-hot-reload.md).

## What reloads

| Change | Result |
|---|---|
| Function, method, initializer, computed property, or `body` | Live |
| New functions, new types, `private` helpers | Live |
| SwiftUI view structure and modifiers | Live, `@State` kept |
| Code in Swift packages that the app builds | Live |
| Add, remove, rename, or retype a stored property | Needs a rebuild |
| Add or remove a method of a non-final class | Needs a rebuild |
| New or deleted file, resources, `Info.plist`, dependencies | Needs a rebuild |
| Initial value of a stored property or `static let` | Reloads, but existing values stay |

## Limits

- **Simulator and Apple silicon only.** The agent rewrites code pages, which a device does not allow.
- **Debug builds only.** `-enable-implicit-dynamic` adds a check to every call and blocks inlining.
- **SwiftUI redraw uses private symbols.** The refresh calls exported SwiftUI functions by their mangled names. If a future iOS renames them, reloads still apply, and views redraw on their next state change. `swapify doctor` reports it.
- **UIKit does not redraw.** Methods get the new bodies, but nothing calls `viewDidLoad` again. Observe the `SwapifyDidReload` notification to rebuild a screen.
- **A reload takes as long as compiling that file.** A view file takes about 0.3 s. A large file with many macros can take several seconds.
- **The app must be in the foreground.** iOS suspends background apps.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `make test` runs the unit tests, and `make e2e` runs the whole pipeline against `Examples/Showcase` in a simulator.

## License

MIT. See [LICENSE](LICENSE).
