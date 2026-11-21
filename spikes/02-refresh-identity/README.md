# Spike 02: SwiftUI refresh, state and type identity

Builds on spike 01 and uses the shared agent in `../../agent/HotAgent.m`.

| Check | Chain roots only | + `refresh` with `incrementPhase` | + `refresh` without it | + new->old accessor jumps |
|---|---|---|---|---|
| Screen shows v2 | no | yes | yes | yes |
| Root view `@State` kept | n/a | no | yes | yes |
| Child view `@State` kept (type defined in the edited file) | n/a | no | no | yes |
| `static let` in the edited file kept | n/a | no | no | yes |
| `as? Greeter` on an instance made by old code | n/a | fails | fails | ok |

Timings on the last run: `dlopen` 5.3 ms, patching 0.33 ms, refresh 2.0 ms.

Run: `./build.sh`, then `python3 -I run.py <device-set> <udid>`.
