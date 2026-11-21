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

Its time is the compile time of the edited file. Large files with many macros, such as TCA reducers, take longer to type-check. Splitting views into smaller files makes reloads faster.

## The build fails only with swapify

swapify adds `-enable-implicit-dynamic` to every Swift target. If a target cannot build with it, open an issue with the error from `.swapify/build.log`.

## Two apps at once

Each `swapify run` picks its own port, so two projects can run side by side in one simulator. Only the foreground app answers.
