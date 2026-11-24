# Recording the Activity demo

Claude Code builds the screen in [DESIGN.md](DESIGN.md) from the starter, and swapify reloads each edit into the running app.

## Prompt

```text
Build the weekly activity screen in DESIGN.md. The app is already running with swapify. Start with a quick rough version of the whole screen, then polish it section by section. After every edit, look at the screenshot swapify sends back, compare it with the spec, and fix what doesn't match before you move on.
```

## Before you record

1. Record on a scratch branch. The agent can commit its work.
2. Use an iPhone simulator with a 393 × 852 pt screen, such as iPhone 16 with iOS 27.2.
3. In `Examples/Activity`, run:

   ```sh
   xcodegen generate
   swapify init
   swapify run --udid <simulator UDID>
   ```

   The app shows only the word "Activity".
4. Start `claude` in `Examples/Activity` once and quit. Approve the folder and the `swapify` server in `.mcp.json`, so no dialog appears in the recording.
5. Start the recording session with `claude --allowedTools mcp__swapify`, so the swapify tools do not ask for permission.
6. Put the Simulator window next to the terminal.

## What to expect

- Two rehearsals took 161 s and 178 s, with 12 and 16 live reloads. A reload took 0.6 to 1.6 s.
- The first pass is a plain screen with a blue default bar chart. Then the agent polishes the sections from top to bottom and fixes what the screenshots show.
- History is below the bottom edge, and the agent cannot scroll. It adds a temporary `.defaultScrollAnchor(.bottom)`, and it relaunches the app twice with `swapify run`. Each relaunch builds for 2 to 7 s.
- At the end, scroll the simulator to show History, and tap "Month" and "Week".

## Reset

In `Examples/Activity`:

```sh
git checkout -- Activity
swapify run --udid <simulator UDID>
```
