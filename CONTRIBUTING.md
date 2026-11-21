# Contributing

## Layout

| Path | Content |
|---|---|
| `Sources/SwapifyCore` | The pipeline: build, patch, launch, agent client, setup, doctor, MCP server |
| `Sources/swapify` | The command-line interface |
| `Agent` | The in-app agent, Objective-C, built by `scripts/build-agent.sh` |
| `Tests/SwapifyCoreTests` | Unit tests (Swift Testing) |
| `Examples/Showcase` | A SwiftUI app with a local package, used by the end-to-end test |
| `docs` | Architecture, protocol, agents, troubleshooting, and research |

## Develop

```sh
swift build            # the CLI; it builds the agent on demand from a source checkout
make test              # unit tests
make e2e               # the whole pipeline against Examples/Showcase in a simulator
```

`make e2e` needs `xcodegen` to generate the example project. It uses the booted simulator or boots the newest iPhone. Pass a device with `python3 -I scripts/e2e.py --udid <UDID>`.

Run the end-to-end test after any change to `Agent/` or the patch pipeline, and on every new Xcode or iOS version.

## A new iOS version

The SwiftUI refresh calls exported functions by mangled name (`Agent/SwiftUIRefresh.m`). To check them on a new simulator runtime, attach LLDB to any running SwiftUI app and look the names up:

```sh
xcrun lldb -p <pid> -o 'image lookup -s "$s7SwiftUI14_UIHostingViewC9viewGraphAA0dF0Cvg"' -o detach
```

To find a renamed function, dump the symbol tables with mangled names and search them:

```sh
xcrun lldb -p <pid> -o "image dump symtab -m SwiftUICore" -o detach > symbols.txt
```

`swapify doctor` reports `swiftUIRefresh: false` when a symbol is missing.

## Style

- Swift 6 language mode. Keep `SwapifyCore` free of terminal output; the CLI and the MCP server format results.
- Agent code is C and Objective-C with `-Wall -Werror` and hidden visibility. Internal functions use the `SWP` prefix.
- Explain ABI offsets and private symbols in comments, with the header or binary they come from.
- One logical change per commit.
