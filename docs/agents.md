# Agents

swapify gives a coding agent two ways in: a Claude Code hook that reloads after every edit, and an MCP server that any MCP client can call.

## Claude Code

`swapify init` writes three files into the project:

| File | Content |
|---|---|
| `.claude/settings.json` | A PostToolUse hook for `Edit`, `Write`, and `MultiEdit` that runs `swapify hook` |
| `.claude/skills/swapify/SKILL.md` | When and how to use swapify, and what needs a rebuild |
| `.mcp.json` | The `swapify mcp` server, for the `ui`, `tap`, and `screenshot` tools |

Existing settings and servers in those files are kept. Run `swapify init --no-agents` to skip them.

The hook reads the event on stdin. It does nothing unless the edited file is Swift and its project was launched with `swapify run`. Otherwise it reloads the file and returns the result as `additionalContext`, which Claude Code shows to the model next to the tool result:

```text
swapify: TaskListView.swift is live in the running app (generation 3, 512 ms).
Screenshot: /…/.swapify/screens/reload-3.png. Visible text: Today | 2 of 3 done | Write the agent | 1 left
```

```text
swapify: TaskModel.swift was not applied. The layout of TaskItem changed (stored properties changed),
which a reload cannot patch. The app still runs the previous code. Run `swapify run` to rebuild.
```

## MCP

```sh
claude mcp add swapify -- swapify mcp
codex mcp add swapify -- swapify mcp
```

Cursor and other clients that read an `mcpServers` JSON file use:

```json
{
  "mcpServers": {
    "swapify": { "command": "swapify", "args": ["mcp"] }
  }
}
```

The server finds the project from its working directory: the nearest `swapify.json` at or above it.

### Tools

| Tool | Arguments | Returns |
|---|---|---|
| `reload` | `files`: paths of the edited Swift files | Summary text, and the screenshot as an image when live |
| `ui` | none | One line per visible element: traits, label, value, frame |
| `tap` | `label`: accessibility label or identifier | The visible text after the tap |
| `screenshot` | `full`: whole simulator screen | The image and its path |
| `run` | none | Build and launch summary |
| `status` | none | The `swapify doctor` checks |

### Protocol versions

The server is dual-era:

- A request with `io.modelcontextprotocol/protocolVersion` in `_meta` is served statelessly, per revision 2026-07-28. Results carry `resultType: "complete"` and `io.modelcontextprotocol/serverInfo`. `server/discover` lists the supported versions.
- An `initialize` request selects the legacy semantics of 2025-11-25, 2025-06-18, 2025-03-26, or 2024-11-05.
- An unknown modern version gets error `-32022` with the supported list.

## A loop that works

1. Call `run` once, or `swapify run` in a terminal.
2. Edit a Swift file. With the hook, the reload happens by itself; with MCP, call `reload` with the file.
3. Read the visible text. Look at the screenshot when the change is visual.
4. Use `tap` and `ui` to test behavior: navigate, toggle, submit.
5. If the result says the layout changed, call `run` and continue from the new state.
