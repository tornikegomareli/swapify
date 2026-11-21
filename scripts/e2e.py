"""End-to-end test of swapify on Examples/Showcase.

Usage:
    python3 -I scripts/e2e.py [--udid <UDID>] [--device-set <path>]
Without a device it uses the booted simulator, or boots the newest iPhone.
"""
import json
import os
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
example = os.path.join(root, "Examples", "Showcase")
swapify = os.path.join(root, ".build", "debug", "swapify")
list_view = os.path.join(example, "Showcase", "TaskListView.swift")
model = os.path.join(example, "Showcase", "TaskModel.swift")
badge = os.path.join(example, "Packages", "TaskUI", "Sources", "TaskUI", "CountBadge.swift")
originals = {path: open(path).read() for path in (list_view, model, badge)}
failures = []


def cli(*args):
    result = subprocess.run([swapify, *args, "--json"], cwd=example, capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"status": "failed", "errors": [result.stdout + result.stderr]}


def edit(path, old, new):
    text = open(path).read()
    assert old in text, f"{old!r} not in {path}"
    open(path, "w").write(text.replace(old, new))


def check(name, condition, detail):
    print(("PASS " if condition else "FAIL ") + name)
    if not condition:
        failures.append(name)
        print("     " + json.dumps(detail)[:600])


def labels():
    return [e["label"] for e in cli("ui")]


def tap(label):
    return subprocess.run([swapify, "tap", label], cwd=example, capture_output=True).returncode == 0


try:
    subprocess.run(["swift", "build"], cwd=root, check=True, capture_output=True)
    if not os.path.exists(os.path.join(example, "Showcase.xcodeproj")):
        subprocess.run(["xcodegen", "generate"], cwd=example, check=True, capture_output=True)
    run = cli("run", *sys.argv[1:])
    check("build, launch and warm-up", run.get("launch", {}).get("warmup", {}).get("status") == "live", run)

    edit(list_view, '.navigationTitle("Today")', '.navigationTitle("Inbox")')
    result = cli("reload", list_view)
    check("visual edit is live", result["status"] == "live" and "Inbox" in result["visibleText"], result)
    check("warm reload under 2 s", result["status"] == "live" and result["timings"]["total"] < 2000,
          result.get("timings"))

    edit(list_view, '.navigationTitle("Inbox")', ".navigationTitle(missingName)")
    result = cli("reload", list_view)
    check("compile error is reported", result["status"] == "compileError", result)
    edit(list_view, ".navigationTitle(missingName)", '.navigationTitle("Inbox")')

    edit(model, "    var done = false\n", "    var done = false\n    var priority = 0\n")
    result = cli("reload", model)
    check("layout change needs rebuild", result["status"] == "needsRebuild", result)
    open(model, "w").write(originals[model])

    edit(model, "        items[index].done.toggle()\n",
         "        items[index].done.toggle()\n        items.sort { !$0.done && $1.done }\n")
    result = cli("reload", model)
    tapped = tap("Write the agent")
    buttons = [label for label in labels() if label in ("Write the agent", "Patch chain roots", "Refresh SwiftUI")]
    check("model behavior change runs", result["status"] == "live" and tapped and buttons[-1] == "Write the agent",
          {"reload": result, "buttons": buttons})

    edit(list_view, '            .navigationTitle("Inbox")\n',
         '            .navigationTitle("Inbox")\n'
         '            .safeAreaInset(edge: .bottom) { Badge(text: leftText()) }\n')
    edit(list_view, "    let model: TaskModel\n",
         "    let model: TaskModel\n\n"
         "    private func leftText() -> String { \"\\(model.items.filter { !$0.done }.count) left\" }\n")
    open(list_view, "a").write("\nprivate struct Badge: View {\n    let text: String\n"
                               "    var body: some View { Text(text).padding().background(.yellow, in: Capsule()) }\n}\n")
    result = cli("reload", list_view)
    check("new function and new view type", result["status"] == "live" and "2 left" in result.get("visibleText", []), result)

    edit(badge, 'Text("\\(remaining) open")', 'Text("\\(remaining) to do")')
    result = cli("reload", badge)
    check("edit in a Swift package", result["status"] == "live" and "2 to do" in result.get("visibleText", []), result)
finally:
    for path, text in originals.items():
        open(path, "w").write(text)

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
