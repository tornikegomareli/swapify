# Changelog

## 0.1.0 (unreleased)

First release.

- `swapify init`, `run`, `reload`, `ui`, `tap`, `screenshot`, `doctor`, and `mcp`.
- Reload through dynamic replacement chain roots, with type, static, field offset, and witness table sharing.
- Layout guard for stored properties and class vtables.
- SwiftUI redraw without resetting `@State`.
- Claude Code hook and skill, and a dual-era MCP server (2026-07-28 and earlier `initialize`-based versions).
- Homebrew formula and `make install`.
- Apple silicon, Xcode 26 or later, iOS 26 or later simulators.
- `swapify run --device`: the same loop on a connected iPhone, with no debugger. Patches bind to the app's types through dyld instead of jumps, the layout guard runs on the Mac, and the agent accepts only connections with the session token, over the CoreDevice tunnel. `reload`, `ui`, `tap`, `screenshot` (`--full` too), `doctor`, `mcp`, and the hook work against it.
