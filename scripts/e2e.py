"""End-to-end test of swapify on Examples/Showcase.

Usage:
    python3 -I scripts/e2e.py [--udid <UDID>] [--device-set <path>]
    python3 -I scripts/e2e.py --device [--udid <name or UDID>]
Without a device it uses the booted simulator, or boots the newest iPhone.
With --device it runs on the connected iPhone, which must be unlocked; the
generated Showcase.xcodeproj then needs a signing team.
"""
import json
import os
import select
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
example = os.path.join(root, "Examples", "Showcase")
swapify = os.path.join(root, ".build", "debug", "swapify")
list_view = os.path.join(example, "Showcase", "TaskListView.swift")
model = os.path.join(example, "Showcase", "TaskModel.swift")
badge = os.path.join(example, "Packages", "TaskUI", "Sources", "TaskUI", "CountBadge.swift")
banner = os.path.join(example, "Showcase", "Banner.swift")
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
    elements = cli("ui")  # a dict with errors when the app does not answer
    return [e["label"] for e in elements] if isinstance(elements, list) else []


def tap(label):
    return subprocess.run([swapify, "tap", label], cwd=example, capture_output=True).returncode == 0


def watch_reload(path, old, new):
    """Starts `swapify watch`, saves the edit as Xcode does (write, then rename), and
    returns the first reload that the watch prints."""
    watch = subprocess.Popen([swapify, "watch", "--json"], cwd=example, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        if select.select([watch.stderr], [], [], 30)[0]:  # "Watching …": the first scan is done
            watch.stderr.readline()
        text = open(path).read()
        assert old in text, f"{old!r} not in {path}"
        open(path + ".saving", "w").write(text.replace(old, new))
        os.replace(path + ".saving", path)
        if not select.select([watch.stdout], [], [], 60)[0]:
            return {"status": "failed", "errors": ["swapify watch printed nothing in 60 s"]}
        line = watch.stdout.readline()
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return {"status": "failed", "errors": [line]}
    finally:
        watch.terminate()
        watch.wait()


try:
    subprocess.run(["swift", "build"], cwd=root, check=True, capture_output=True)
    if not os.path.exists(os.path.join(example, "Showcase.xcodeproj")):
        subprocess.run(["xcodegen", "generate"], cwd=example, check=True, capture_output=True)
    # A private type with static metadata, built into the app (issue #7): patched code must
    # use the app's metadata, or SwiftUI sees two types. Its printed name has its context's address.
    edit(list_view, '            .navigationTitle("Today")\n',
         '            .navigationTitle("Today")\n'
         '            .safeAreaInset(edge: .bottom) { Text(String(reflecting: Probe.self)).font(.caption2) }\n')
    open(list_view, "a").write("\nprivate struct Probe {}\n")
    run = cli("run", *sys.argv[1:])
    check("build, launch and warm-up", run.get("launch", {}).get("warmup", {}).get("status") == "live", run)
    built_probe = [label for label in labels() if label.endswith(".Probe")]

    edit(list_view, '.navigationTitle("Today")', '.navigationTitle("Inbox")')
    result = cli("reload", list_view)
    check("visual edit is live", result["status"] == "live" and "Inbox" in result["visibleText"], result)
    check("warm reload under 2 s", result["status"] == "live" and result["timings"]["total"] < 2000,
          result.get("timings"))
    patched_probe = [label for label in labels() if label.endswith(".Probe")]
    check("a private type keeps the app's metadata", built_probe and patched_probe == built_probe,
          {"built": built_probe, "patched": patched_probe})

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

    # A stored property added to the model, a class the app was built with: the existing
    # TaskModel object keeps its layout and the new property lives beside it.
    edit(model, "    ]\n", "    ]\n    var taps = 0\n")
    edit(model, "        items[index].done.toggle()\n", "        items[index].done.toggle()\n        taps += 1\n")
    edit(list_view, 'Section("\\(model.items.filter(\\.done).count) of \\(model.items.count) done")',
         'Section("\\(model.taps) taps")')
    result = cli("reload", model, list_view)
    check("new stored property of a class is live", result["status"] == "live" and result.get("sideFields") == ["TaskModel.taps"]
          and any(label.upper() == "0 TAPS" for label in result.get("visibleText", [])), result)
    tapped = tap("Refresh SwiftUI")
    shown = labels()
    tapped = tap("Refresh SwiftUI") and tapped  # undone, so the checks below see two open tasks
    shown_again = labels()
    check("the new property changes and the view follows",
          tapped and any(label.upper() == "1 TAPS" for label in shown) and any(label.upper() == "2 TAPS" for label in shown_again),
          {"tapped": tapped, "ui": shown, "ui after the second tap": shown_again})

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

    open(banner, "w").write("import SwiftUI\n\nstruct Banner: View {\n    let text: String\n\n"
                            "    var body: some View { Text(text).padding().background(.mint, in: Capsule()) }\n}\n")
    result = cli("reload", banner)
    check("new file is live", result["status"] == "live", result)
    edit(list_view, '            .navigationTitle("Inbox")\n',
         '            .navigationTitle("Inbox")\n'
         '            .safeAreaInset(edge: .top) { Banner(text: "New banner") }\n')
    result = cli("reload", list_view)
    check("existing file shows the new file's view",
          result["status"] == "live" and "New banner" in result.get("visibleText", []) and banner in result.get("compiled", []),
          result)

    open(banner, "w").write("import SwiftUI\n\nstruct Banner: View {\n    let text: String\n"
                            "    var detail = \"Two more fields\"\n    var tint = Color.orange\n\n"
                            "    var body: some View {\n        VStack { Text(text); Text(detail) }\n"
                            "            .padding().background(tint, in: Capsule())\n    }\n}\n")
    result = cli("reload", banner)
    shown = labels()
    check("new type's stored properties change live",
          result["status"] == "live" and "New banner" in shown and "Two more fields" in shown, {"reload": result, "ui": shown})

    result = watch_reload(list_view, '.navigationTitle("Inbox")', '.navigationTitle("Watched")')
    shown = labels()
    check("watch reloads a saved file", result["status"] == "live" and "Watched" in shown, {"reload": result, "ui": shown})

    # SwiftUI gives a bar with nothing in it an accessibility element that has no frame.
    edit(list_view, '            .navigationTitle("Watched")\n',
         '            .navigationTitle("Watched")\n'
         '            .safeAreaBar(edge: .bottom) { if model.items.isEmpty { Text("All done") } }\n')
    result = cli("reload", list_view)
    shown = labels()
    check("ui answers with an empty bar on screen", result["status"] == "live" and "Watched" in shown,
          {"reload": result, "ui": shown})

    edit(list_view, "    let model: TaskModel\n", "    let model: TaskModel\n    let extra = 1\n")
    result = cli("reload", list_view)
    check("app type's stored properties still need a rebuild", result["status"] == "needsRebuild", result)
finally:
    for path, text in originals.items():
        open(path, "w").write(text)
    if os.path.exists(banner):
        os.remove(banner)

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
