# Recording the Activity demo

Claude Code builds the screen in [DESIGN.md](DESIGN.md) from the starter, and swapify reloads each edit into the running app.

## Prompt

```text
Build the weekly activity screen in DESIGN.md. The app is already running with swapify. Start with a quick rough version of the whole screen, then polish it section by section. After every edit, look at the screenshot swapify sends back, compare it with the spec, and fix what doesn't match before you move on.
```

## Before you record

1. Use an iPhone simulator with a 393 × 852 pt screen, such as iPhone 16 with iOS 27.2.
2. In `Examples/Activity`, run:

   ```sh
   xcodegen generate
   swapify init
   swapify run --udid <simulator UDID>
   ```

   The app shows only the word "Activity".
3. Start `claude` in `Examples/Activity` once and quit. Approve the folder and the `swapify` server in `.mcp.json`, so no dialog appears in the recording.
4. Start the recording session with `claude --allowedTools mcp__swapify`, so the swapify tools do not ask for permission.
5. Put the Simulator window next to the terminal.

## What to expect

- The last rehearsal took 127 s, with 14 live reloads, no rebuild, and no relaunch. A reload took 0.6 to 1.3 s.
- The first pass is a plain screen with a blue default bar chart. Then the agent polishes the sections from top to bottom and fixes what the screenshots show.
- The agent creates new files, such as `RangePicker.swift` and `StatCard.swift`. Each one is live in under a second.
- `CLAUDE.md` tells the agent not to commit.
- At the end, tap "Month" and "Week" in the simulator.

## Reset

In `Examples/Activity`:

```sh
git checkout -- Activity
git clean -f Activity
swapify run --udid <simulator UDID>
```

`git clean` deletes the files the agent created. `Activity/` is a synchronized folder, so a file left in it would be built into the starter.
