# Agent wire protocol

The CLI and the MCP server talk to `SwapifyAgent` inside the app over TCP on `127.0.0.1:$SWAPIFY_PORT`. The CLI picks a free port at each launch and stores it in `.swapify/session.json`.

On a device the agent listens on every interface, and the CLI connects through the CoreDevice tunnel address, an encrypted link over the cable or the network. Each connection must start with `auth`; see below.

Each request is one line of text. Each reply is one line of JSON. Every reply has `ok`, and failed replies have `error`. The current protocol version is 1. `ping` returns it, and the CLI refuses an agent with a different version.

## auth (device only)

```text
auth 0b02fbb3e53df5cd524edb054571099f
{"ok":true}
```

The token is `$SWAPIFY_TOKEN`, 128 random bits that the CLI makes at each launch and keeps in `.swapify/session.json` (mode 0600). The agent compares it in constant time. A wrong token gets `{"ok":false,"error":"not authorized"}` and the connection closes. So does a connection with no complete first line within 2 s, so a stranger cannot hold the agent's single accept loop. A device agent started without `SWAPIFY_TOKEN` does not listen.

## ping

```text
ping
{"ok":true,"protocol":1,"generation":3,"bundleID":"dev.hotreload.showcase","swiftUIRefresh":true}
```

`generation` counts applied patches since launch. `swiftUIRefresh` is false if the app uses SwiftUI and this iOS version lacks the SwiftUI symbols that `refresh` uses. An app without SwiftUI reports true. `device` is true on a device, and `traced` says whether a debugger is attached (`P_TRACED`):

```text
{"ok":true,"protocol":1,"generation":0,"bundleID":"dev.swapify.habits","swiftUIRefresh":true,"device":true,"traced":false}
```

## put (device only)

```text
put 3-1A2B3C4D.dylib 97920
<97920 bytes>
{"ok":true,"path":"/private/var/mobile/Containers/Data/Application/…/tmp/3-1A2B3C4D.dylib","bytes":97920,"ms":4.3}
```

Stores the bytes that follow the line in the app's `tmp/`, under the last path component of the name. A device app cannot read the Mac's files, so the CLI sends each patch this way and then sends `load` with the returned path.

## load

```text
load /path/to/.swapify/patches/4-1A2B3C4D/patch.dylib
{"ok":true,"generation":4,"replaced":12,"added":0,"objcReplaced":6,"objcAdded":0,"sharedAccessors":7,"sharedWitnessTables":3,"sharedMetadata":1,"tooSmall":0,"dlopenMs":3.1,"patchMs":0.4}
```

| Field | Meaning |
|---|---|
| `replaced` | Chain roots in the app and earlier patches that now forward to this patch |
| `added` | Chain roots of functions the app does not have: new functions, and functions of types that are new since the build |
| `objcReplaced` | Objective-C methods of app classes that now run the patch's `@objc` thunk: overrides such as `viewDidLoad`, data source and delegate methods, actions |
| `objcAdded` | Objective-C methods new in the edit, added to the app's classes. Simulator only |
| `sharedAccessors` | Patch accessors and addressors that now jump to the app's |
| `sharedWitnessTables` | Witness tables copied from the app |
| `sharedMetadata` | Metadata slots filled with the app's metadata (simulator) |
| `tooSmall` | Accessors shorter than the 16-byte jump; they were left alone |

A layout change rejects the patch:

```text
{"ok":false,"needsRebuild":true,"error":"layout changed","type":"$s8Showcase8TaskItemVMn","reason":"stored properties changed"}
```

On a device, a new `@objc` member of an app class also rejects the patch, because a device patch registers no classes:

```text
{"ok":false,"needsRebuild":true,"reason":"Notes.ListViewController has a new @objc method or property. On a device that needs a rebuild.","error":"…"}
```

## load-side

```text
load-side $s8Showcase9TaskModelCMn /path/to/.swapify/patches/5-9F8E7D6C/patch.dylib
```

`load` for a patch that keeps the new stored properties of classes in side storage (Agent/SideFields.m). The CLI rewrote the patch so that existing objects keep their layout, and the layout guard skips the listed type descriptors, separated by commas. The reply is `load`'s.

## refresh

```text
refresh
{"ok":true,"hosts":6,"ms":4.3,"uikit":{"ok":true,"rebuilt":1,"unloaded":0,"deferred":0,"injected":0,"redrawn":1,"reloadedData":1,"ms":6.6}}
```

Runs on the main thread. Invalidates the view graph of every `_UIHostingView`, then refreshes UIKit for the classes the last patch touched (Agent/UIKitRefresh.m):

| Field | Meaning |
|---|---|
| `rebuilt` | View controllers on screen whose view was loaded again in place |
| `unloaded` | View controllers off screen whose view was unloaded; UIKit loads it again when it shows it |
| `deferred` | View controllers in a transition; each is rebuilt when the transition completes |
| `injected` | View controllers and views that implement `injected()` and got that call instead |
| `redrawn` | Views of patched classes that got `setNeedsLayout` and `setNeedsDisplay` |
| `reloadedData` | Table and collection views whose data source or delegate is patched |

## snapshot

```text
snapshot /path/to/.swapify/screens/reload-4.png
{"ok":true,"path":"/path/to/.swapify/screens/reload-4.png","ms":46.1,"size":[402,874]}
```

Renders the foreground windows at 1x into a PNG at the host path. Simulator apps can write to host paths.

Without a path, the PNG comes back in the reply as base64. A device app uses this form:

```text
snapshot
{"ok":true,"png":"iVBORw0KGgo…","ms":39.2,"size":[466,678]}
```

If no window of the app is in the foreground, the reply is `{"ok":false,"error":"no visible window","applicationState":1,"sceneStates":[1]}`, with the `UIApplication` and `UIScene` activation states.

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

Activates the element whose label or identifier equals the argument, or else the first whose label contains it. A table or collection view cell is selected through its view, as a tap selects it. A control that does not activate for accessibility, such as a navigation bar's back button, gets its tap action.
