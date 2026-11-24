# Spike 05: an end-to-end reload of Habits on an iPhone

Goal: edit `Examples/Habits/Habits/TodayView.swift` on the Mac, see the running Habits app on the phone change in about a second, keep its state, and get a screenshot and the visible text back on the Mac. No debugger.

Answer: it works. Measured on 2026-11-24 on "Doomile" (iPhone19,4, iOS 27.2, build 24B91020) with Xcode 27.2. Every step ran over the CoreDevice tunnel on Wi-Fi, with no cable and no debugger: the agent reported `"traced": false` at the start and at the end.
- **Edit to screen:** 738 to 848 ms from saving the file to having the screenshot and visible text on the Mac (final run).
- **State:** a habit marked done stays done through a later edit.
- **Logic:** an edit to the store's code takes effect.
- **Compile error:** reported in 196 ms, and nothing changes on the phone.

## What was done

| Step | Result |
|---|---|
| 1. Build Habits for the device | `build.sh`: swapify's reload settings, plus `-Xfrontend -enable-private-imports`, team `539293JFA3`, bundle ID `dev.swapify.spike.device.habits`. Xcode's default `ENABLE_DEBUG_DYLIB=YES` works, so no fallback was needed. The Swift code is in `Habits.debug.dylib`, which exports 153 Habits symbols, and the patches bind to them |
| 2. Get the agent in | `SwapifyAgent.dylib`, built for arm64 iOS and signed with the app's certificate, is copied into the app's `tmp/`. The app is launched with `devicectl device process launch --console --environment-variables '{"DYLD_INSERT_LIBRARIES": "<container>/tmp/SwapifyAgent.dylib", "SWAPIFY_PORT": "7791"}'`. dyld accepted it, and the agent logged `[swapify] listening on [::]:7791`. Linking the agent into the build was not needed. From launch to the agent listening: 763 to 770 ms |
| 3. Reach the agent | On the device the agent listens on every interface. The Mac reads the tunnel address from `devicectl device info details` and connects to `[<tunnel>]:7791`. Reading the address and connecting take 480 to 610 ms, mostly the `devicectl` call. The tunnel address was different in every session |
| 4. Device patch path | The patch comes from spike 04's binder: `patch.py` with `../04-device-bind/rewrite_ir.py`. On a device the agent skips the 16-byte jumps, the field-offset and witness-table copies, and the layout guard. It still copies chain roots, and `refresh` still redraws. `swiftUIRefresh` is `true` on the device, so SwiftUI's refresh symbols are there |
| 5. Transport | `put <name> <size>` plus the raw bytes stores the patch in the app's `tmp/`, then `load <path>` loads it. A `snapshot` with no path returns the PNG in the reply (base64). `ui` already returns text |
| 6. The reloads | `session.py` replays the recorded demo: v1 (progress ring), v2 (cards with buttons), tap Run, v3 (tiles), a compile error, store1 (a logic edit in `HabitStore.swift`), and tap Meditate. It restores both source files at the end |

## Final run (`session-final.log`)

| Step | Save to screenshot and text on the Mac | What the agent read on screen afterwards |
|---|---|---|
| Launch (v0) | | Today, 0 of 4 done, Run 12 days, Read 4 days, Meditate 27 days, Water 9 days |
| v1: progress ring (adds the `ProgressRing` view) | 756 ms | Today, 0, of 4 done, Run, … |
| v2: cards with buttons (adds `HabitCard`) | 757 ms | Today, 0, of 4 done, Run = 12 days, Read = 4 days, … |
| `tap Run` | | Today, 1, of 4 done, Run = 12 days, done, … |
| v3: tiles (adds `HabitTile`) | 848 ms | Today, 1, of 4 done, Run = 12 days, done, … (state kept) |
| Compile error (`todayTitle` undefined) | reported after 196 ms; nothing sent | the text is identical to after v3 |
| store1: `toggle` also changes the streak | 738 ms | the same as before (no visual change) |
| `tap Meditate` | | Today, 2, of 4 done, …, Meditate = 28 days, done (the new `toggle` ran) |

The compiler's error text comes back as is:

```text
TodayView.swift:26:30: error: cannot find 'todayTitle' in scope
```

An earlier full run gave v1 864 ms, v2 1023 ms, v3 987 ms, and the compile error in 225 ms.

## Time per step (final run, ms)

| Step | v1 | v2 | v3 | store1 |
|---|---|---|---|---|
| Compile to IR (the build's frontend command) | 170 | 231 | 230 | 130 |
| Rewrite IR (`rewrite_ir.py`, Python) | 62 | 76 | 77 | 50 |
| clang `-c` | 38 | 48 | 51 | 25 |
| Link | 137 | 136 | 137 | 138 |
| Codesign | 54 | 45 | 45 | 45 |
| Send the patch over the tunnel | 48 (187 KB) | 29 (256 KB) | 114 (260 KB) | 159 (98 KB) |
| `load` round trip | 35 | 31 | 36 | 35 |
| … of which `dlopen` | 19.4 | 15.2 | 18.7 | 19.0 |
| … of which chain roots | 1.43 (2 replaced, 2 added) | 1.44 (6, 2) | 1.43 (10, 2) | 1.44 (12, 0) |
| `refresh` (SwiftUI redraw) | 31 | 43 | 40 | 29 |
| Screenshot to the Mac (PNG in the reply) | 144 | 90 | 87 | 94 |
| Visible text | 27 | 17 | 21 | 22 |
| **Total** | **756** | **757** | **848** | **738** |

Building the patch on the Mac takes 388 to 540 ms, 53 to 71% of the total. Everything after it, on the phone and over the network, takes 220 to 350 ms. The screenshot is 76 to 108 KB at 1x, 466 × 678 points, which is the window this phone gives the app. The agent renders it in 37 to 54 ms.

## Screenshots

`screens/` has a PNG and the visible text for each step. I looked at all of them:
- `0-launch.png` shows the plain list (v0).
- `1-v1.png` shows the progress ring.
- `2-v2.png` shows the cards.
- `4-v3.png` shows the tiles with Run done (blue tile, checkmark) and the ring at 1 of 4.

`3-tap-run.png` and `7-tap-meditate.png` show the state before their taps. The screenshot was taken right after the tap, before SwiftUI drew the animated change. The visible text taken about 100 ms later shows the change, and `4-v3.png` shows Run done. After that run, `session.py` waits 600 ms after a tap; that change has not run on the device.

## Checks

| Check | Result |
|---|---|
| The screen changed | Yes: `0-launch.png` to `1-v1.png` to `2-v2.png` to `4-v3.png` |
| The state survived | Yes: Run is still done after v3 (text `Run = 12 days, done`, ring at 1 of 4 in `4-v3.png`) |
| No debugger | `"traced": false` (`P_TRACED=0`) in the first and the last `ping` |
| A second edit on top of the first | Yes: v1, then v2, then v3, then store1. The roots replaced grew 2, 6, 10, 12, because each patch also rewrites the earlier patches' roots |
| A compile error is reported and changes nothing | Yes: the compiler's message, no patch sent, the text unchanged |
| End to end and per step | See the two tables above |

## Changes to swapify (not committed, each marked `device:`)

Every agent change keeps the simulator behavior. swapify's own end-to-end test (`scripts/e2e.py`) passed all 9 checks with the changed agent, on a new iOS 27.2 simulator that I deleted afterwards. `make e2e` failed first, for an unrelated reason: it picked an already booted simulator with an older iOS, and the install failed with "Showcase Requires a Newer Version of iOS".

- **`Agent/Server.m`**
  - On a device, it listens on `[::]` (IPv6 and IPv4). The simulator keeps `127.0.0.1`.
  - It adds `put <name> <size>` plus raw bytes, which writes a file to the app's `tmp/`.
  - A `snapshot` with no path returns the PNG in the reply.
  - `ping` adds `device` and `traced` (`P_TRACED`).
- **`Agent/Inspector.m`**
  - `SWPSnapshot(nil, …)` returns the PNG as base64.
  - A "no visible window" error now carries the app's and the scenes' activation states.
- **`Agent/Patcher.m`**
  - On a device (`#if TARGET_OS_SIMULATOR`), it skips the layout guard, the accessor jumps, and the field-offset and witness-table copies, because a bound patch defines none of the app's types and code cannot be written there. Chain roots and everything after them are unchanged.
  - Three helpers the device build no longer uses are marked `__unused`, for `-Werror`.
- **`docs/research/spikes/04-device-bind/rewrite_ir.py`**
  - It now keeps the registration records (`__swift5_types`, `__swift5_proto`, `__swift5_fieldmd`, `__swift5_assocty`, `__objc_classlist`) of types and conformances that only the patch defines. Every Habits edit adds a view.
  - Spike 04's two patches come out the same as before.

The CLI (`Sources/`) is unchanged. The Mac side of this spike is `session.py` and `patch.py`.

## Problems seen

- **The phone locked.** It was locked once more before the final run. Launches are refused while it is locked.
- **`devicectl --console` owns the app.** It forwards signals to the app, so when the shell command that held it ended, the app ended ("The app terminated with the exit code 0"). The session keeps that process alive for its whole duration.
- **Foreground but inactive.**
  - In two of the four session attempts, the app became foreground-inactive after launch (`applicationState: 1`, scene state 1), and `snapshot` found no visible window.
  - The second of them started right after the phone was unlocked, and its first `ui` also hung past the 30 s socket timeout, so the session reconnected.
  - The cause is unknown. A system overlay over the app is likely, but this was not verified.
  - `session.py` now waits up to 10 s for the app to become active. The final run did not need it.
- **The agent serves one connection at a time.** A client that gives up while a command is still blocked on the main thread waits for that command to finish before its new connection is served.

## What `swapify run --device` needs

1. **Build:** a device build, with `-destination id=<udid>`, the reload settings, `-Xfrontend -enable-private-imports`, and the project's own signing. `Xcode.builtApp` also has to look in `Debug-iphoneos`.
2. **Agent build:** a device slice of `scripts/build-agent.sh`, signed at run time with the certificate that signed the app (taken from the built app's signature).
3. **Launch:**
   - Install with `devicectl device install app`.
   - Copy the agent into the app's `tmp/`; `devicectl copy --json-output` gives its full path.
   - Launch with `devicectl device process launch --console --environment-variables {DYLD_INSERT_LIBRARIES, SWAPIFY_PORT}`.
   - Keep that `devicectl` process for the session.
4. **Connect:**
   - Read the CoreDevice tunnel address from `devicectl` before every connection, and reconnect when the tunnel changes.
   - Accept connections only on the tunnel interface, or add a token. Today any device on the same Wi-Fi can reach the agent. It could read the screen and tap; it could not load code that the team did not sign.
5. **Patch builder for devices:** compile to IR, rewrite, clang, link, and codesign with the app's certificate. Then `put` and `load` over the socket. `rewrite_ir.py` is Python; port it to Swift or ship it.
6. **Layout guard on the Mac:** the agent cannot check layouts of bound patches. The CLI has to compare the type descriptors in the patch IR, before the rewrite, with the app build's.
7. **Screenshots and text:** `snapshot` with no path. Expect a foreground-inactive app, and report it.

## Still unknown

- **USB cable:** every number here is over Wi-Fi.
- **Layout changes** (a new stored property): there is no guard on the device yet, and a layout change would probably crash the app. Not tried.
- **Long sessions:** the tunnel address changes, and the reconnect path never ran with a live patch in flight.
- **Many reloads in one process:** each patch stays loaded, about 100 to 260 KB each. Memory over hundreds of reloads was not measured.
- **Debugging:** patch code has no debug info, because the IR step drops `-g`. LLDB cannot be attached at the same time either; a second debugger session was not tested.
- **Distribution signing, Developer Mode off, other iOS versions, and other devices.**

## Files

- `build.sh` builds Habits and the device agent.
- `patch.py` builds one bound patch.
- `session.py` runs the whole session: launch, the reloads, taps, and the error case.
- `run.sh` runs `build.sh` and `session.py`, copies the screens, and uninstalls the app. The phone must be unlocked with its screen on.
- `edits/` holds the demo's versions of `TodayView.swift` (v1, v2, v3 from `capture/take/sources` of the site repo), the error edit, and `HabitStore.swift` (store1).
- `screens/` holds the PNG and text of every step of the final run, and `session-final.log` is its log.
