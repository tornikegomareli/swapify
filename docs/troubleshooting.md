# Troubleshooting

Start with `swapify doctor`. It checks the Mac, Xcode, the agent, the project, the build, the simulator, and the running app.

## "The app did not answer"

The app crashed, or iOS suspended it: it is in the background, or stopped at a breakpoint in a debugger. Bring it to the foreground, or run `swapify run --no-build`. Crash reports are in `~/Library/Logs/DiagnosticReports/<App>-*.ips`, and the app's output is in `.swapify/console.log`.

## "has no compile command"

The file was not part of the last build. It is new, or it belongs to a target the scheme does not build. Run `swapify run`.

## "No compile commands were captured"

The build was up to date and `.swapify/session.json` had no commands from an earlier build. Delete `.swapify/DerivedData` and run `swapify run`.

## "The layout of X changed"

The edit added, removed, renamed, or retyped a stored property, or added or removed a method of a non-final class. New code would read existing objects with the wrong layout, so swapify did not apply it. Run `swapify run`.

## A reload is live, but the screen did not change

- The edited code does not run during a redraw. For example, it is in `App.init`, a `static let` initializer, or an `onAppear` that already ran. Trigger it again: navigate away and back, or call it from a view.
- UIKit screens do not redraw on their own. Observe `SwapifyDidReload` and rebuild the view.
- `swapify doctor` reports whether the SwiftUI refresh symbols exist on this iOS version.

## A reload is slow

Its time is the compile time of the slowest file changed since the last build: each reload compiles all of them, in parallel. Large files with many macros, such as TCA reducers, take longer to type-check. Splitting views into smaller files makes reloads faster.

## The build fails only with swapify

swapify adds `-enable-implicit-dynamic` to every Swift target. If a target cannot build with it, open an issue with the error from `.swapify/build.log`.

## Two apps at once

Each `swapify run` picks its own port, so two projects can run side by side in one simulator. Only the foreground app answers.

## On an iPhone

`swapify doctor` checks the iPhone of the last `swapify run --device`: connected, Developer Mode on, unlocked.

- **"Doomile is locked."** iOS does not launch apps on a locked phone, and it suspends a running app when the phone locks. Unlock it. A running app keeps its state.
- **"The app on Doomile did not answer: the phone's screen is off …"** The phone still counts as unlocked for a while after its screen goes dark, but the app is suspended. Wake the phone and bring the app to the front. Keep the screen on while you work, for example with a longer Auto-Lock time.
- **"Developer Mode is off."** Turn it on in Settings > Privacy & Security > Developer Mode, and restart the phone.
- **"No iPhone is connected."** Connect it by cable, or keep it on the same Wi-Fi as the Mac, and pair it once in Xcode > Window > Devices and Simulators. Answer "Trust This Computer" on the phone. Several connected devices: pick one with `swapify run --device --udid <name or UDID>`.
- **"The project has no signing team."** A device build signs the app with the project's own settings. In Xcode, select the app target, open Signing & Capabilities, and pick a Team. With a free Apple ID, also trust the developer on the phone in Settings > General > VPN & Device Management.
- **"The agent refused the session token."** The app was launched by an earlier `swapify run --device`. Run it again.
