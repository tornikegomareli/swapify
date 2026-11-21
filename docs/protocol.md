# Agent wire protocol

The CLI and the MCP server talk to `SwapifyAgent` inside the app over TCP on `127.0.0.1:$SWAPIFY_PORT`. The CLI picks a free port at each launch and stores it in `.swapify/session.json`.

Each request is one line of text. Each reply is one line of JSON. Every reply has `ok`, and failed replies have `error`. The current protocol version is 1. `ping` returns it, and the CLI refuses an agent with a different version.

## ping

```text
ping
{"ok":true,"protocol":1,"generation":3,"bundleID":"dev.hotreload.showcase","swiftUIRefresh":true}
```

`generation` counts applied patches since launch. `swiftUIRefresh` is false if this iOS version lacks the SwiftUI symbols that `refresh` uses.

## load

```text
load /path/to/.swapify/patches/4-1A2B3C4D/patch.dylib
{"ok":true,"generation":4,"replaced":12,"added":0,"sharedAccessors":7,"sharedWitnessTables":3,"tooSmall":0,"dlopenMs":3.1,"patchMs":0.4}
```

| Field | Meaning |
|---|---|
| `replaced` | Chain roots in the app and earlier patches that now forward to this patch |
| `added` | Chain roots with no old counterpart: new functions |
| `sharedAccessors` | Patch accessors and addressors that now jump to the app's |
| `sharedWitnessTables` | Witness tables copied from the app |
| `tooSmall` | Accessors shorter than the 16-byte jump; they were left alone |

A layout change rejects the patch:

```text
{"ok":false,"needsRebuild":true,"error":"layout changed","type":"$s8Showcase8TaskItemVMn","reason":"stored properties changed"}
```

## refresh

```text
refresh
{"ok":true,"hosts":6,"ms":4.3}
```

Invalidates the view graph of every `_UIHostingView`. Runs on the main thread.

## snapshot

```text
snapshot /path/to/.swapify/screens/reload-4.png
{"ok":true,"path":"/path/to/.swapify/screens/reload-4.png","ms":46.1,"size":[402,874]}
```

Renders the foreground windows at 1x into a PNG at the host path. Simulator apps can write to host paths.

## ui

```text
ui
{"ok":true,"elements":[{"label":"Today","value":"","identifier":"","traits":["header","text"],"frame":[16,120,95,41]}, …]}
```

Visible accessibility elements, sorted top to bottom, then left to right. Frames are in points. The first `ui` or `tap` turns accessibility on and waits 500 ms for SwiftUI to build its tree.

## tap

```text
tap Write the agent
{"ok":true,"element":{"label":"Write the agent","value":"","identifier":"","traits":["button"],"frame":[16,208,370,52]}}
```

Activates the element whose label or identifier equals the argument, or else the first whose label contains it.
