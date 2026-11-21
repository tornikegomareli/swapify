"""End-to-end test of hotreload on Examples/Showcase.

Needs a booted simulator. Usage:
    python3 -I scripts/e2e.py [--udid <UDID>] [--device-set <path>]
"""
import json
import os
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
example = os.path.join(root, "Examples", "Showcase")
hotreload = os.path.join(root, ".build", "debug", "hotreload")
list_view = os.path.join(example, "Showcase", "TaskListView.swift")
model = os.path.join(example, "Showcase", "TaskModel.swift")
badge = os.path.join(example, "Packages", "TaskUI", "Sources", "TaskUI", "CountBadge.swift")
originals = {path: open(path).read() for path in (list_view, model, badge)}
failures = []


def cli(*args):
    result = subprocess.run([hotreload, *args], cwd=example, capture_output=True, text=True)
    return json.loads(result.stdout)


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
    return [e["label"] for e in cli("ui")["elements"]]


try:
    subprocess.run(["swift", "build"], cwd=root, check=True, capture_output=True)
    if not os.path.exists(os.path.join(example, "Showcase.xcodeproj")):
        subprocess.run(["xcodegen", "generate"], cwd=example, check=True, capture_output=True)
    build = cli("build", "--project", "Showcase.xcodeproj", "--scheme", "Showcase")
    check("build", build["ok"], build)
    launch = cli("launch", *sys.argv[1:])
    check("launch and warm-up", launch["ok"] and launch.get("warmup", {}).get("ok"), launch)

    edit(list_view, '.navigationTitle("Today")', '.navigationTitle("Inbox")')
    result = cli("reload", list_view)
    check("visual edit is live", result["ok"] and "Inbox" in result["visibleText"], result)
    check("warm reload under 2 s", result["ok"] and result["ms"]["total"] < 2000, result.get("ms"))

    edit(list_view, '.navigationTitle("Inbox")', ".navigationTitle(missingName)")
    result = cli("reload", list_view)
    check("compile error is reported", not result["ok"] and result.get("stage") == "compile", result)
    edit(list_view, ".navigationTitle(missingName)", '.navigationTitle("Inbox")')

    edit(model, "    var done = false\n", "    var done = false\n    var priority = 0\n")
    result = cli("reload", model)
    check("layout change needs rebuild", result.get("needsRebuild") is True, result)
    open(model, "w").write(originals[model])

    edit(model, "        items[index].done.toggle()\n",
         "        items[index].done.toggle()\n        items.sort { !$0.done && $1.done }\n")
    result = cli("reload", model)
    tap = cli("tap", "Write the agent")
    buttons = [label for label in labels() if label in ("Write the agent", "Patch chain roots", "Refresh SwiftUI")]
    check("model behavior change runs", result["ok"] and tap["ok"] and buttons[-1] == "Write the agent",
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
    check("new function and new view type", result["ok"] and "2 left" in result.get("visibleText", []), result)

    edit(badge, 'Text("\\(remaining) open")', 'Text("\\(remaining) to do")')
    result = cli("reload", badge)
    check("edit in a Swift package", result["ok"] and "2 to do" in result.get("visibleText", []), result)
finally:
    for path, text in originals.items():
        open(path, "w").write(text)

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
