"""End-to-end test of swapify on Examples/Notes, a UIKit app built in code.

Usage:
    python3 -I scripts/e2e-uikit.py [--udid <UDID>] [--device-set <path>]
    python3 -I scripts/e2e-uikit.py --device [--udid <name or UDID>]
Without a device it uses the booted simulator, or boots the newest iPhone.
With --device it runs on the connected iPhone, which must be unlocked; the
generated Notes.xcodeproj then needs a signing team.
"""
import json
import os
import subprocess
import sys
import time

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
example = os.path.join(root, "Examples", "Notes")
swapify = os.path.join(root, ".build", "debug", "swapify")
listing = os.path.join(example, "Notes", "ListViewController.swift")
badge = os.path.join(example, "Notes", "BadgeView.swift")
detail = os.path.join(example, "Notes", "DetailViewController.swift")
originals = {path: open(path).read() for path in (listing, badge, detail)}
failures = []
device = "--device" in sys.argv


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
    elements = cli("ui")
    return [e["label"] for e in elements] if isinstance(elements, list) else []


def tap(label):
    return subprocess.run([swapify, "tap", label], cwd=example, capture_output=True).returncode == 0


try:
    subprocess.run(["swift", "build"], cwd=root, check=True, capture_output=True)
    if not os.path.exists(os.path.join(example, "Notes.xcodeproj")):
        subprocess.run(["xcodegen", "generate"], cwd=example, check=True, capture_output=True)
    run = cli("run", *sys.argv[1:])
    check("build, launch and warm-up", run.get("launch", {}).get("warmup", {}).get("status") == "live", run)

    # An override that UIKit calls through the Objective-C runtime.
    edit(listing, 'title = "Notes"', 'title = "Inbox"')
    result = cli("reload", listing)
    check("viewDidLoad edit is live", result["status"] == "live" and "Inbox" in result.get("visibleText", []), result)

    # A data source method.
    edit(listing, "content.text = notes[indexPath.row]", 'content.text = "• " + notes[indexPath.row]')
    result = cli("reload", listing)
    check("cellForRowAt edit is live", result["status"] == "live" and "• Buy milk" in result.get("visibleText", []), result)

    # A custom view's init, in another file, after the screen's state changed.
    tapped = tap("Add")
    shown = labels()
    edit(badge, '"Count: \\(count)"', '"Total: \\(count)"')
    result = cli("reload", badge)
    check("a custom view's code is live and the screen keeps its state",
          tapped and "Count: 1" in shown and result["status"] == "live" and "Total: 1" in result.get("visibleText", []),
          {"before": shown, "reload": result})

    # A pushed screen stays pushed while its code reloads.
    tapped = tap("• Buy milk")
    edit(detail, "label.text = note", 'label.text = "Note: " + note')
    result = cli("reload", detail)
    shown = result.get("visibleText", [])
    check("a pushed screen reloads in place",
          tapped and result["status"] == "live" and "Note: Buy milk" in shown and "• Call the bank" not in shown,
          {"tapped": tapped, "reload": result})
    tap("BackButton")  # UIKit's identifier; the label is the previous title, or "Back"
    time.sleep(1)  # the pop animates

    # A new target-action: a method the app's class did not have.
    edit(listing, '        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add"',
         '        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self,\n'
         '                                                           action: #selector(clear))\n'
         '        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add"')
    edit(listing, "    private func add() {",
         "    @objc private func clear() {\n        notes.removeAll()\n        table.reloadData()\n    }\n\n"
         "    private func add() {")
    result = cli("reload", listing)
    if device:  # a device patch registers no classes, so the new method cannot get into the app's
        check("a new @objc action needs a rebuild on a device",
              result["status"] == "needsRebuild" and "@objc" in (result.get("reason") or ""), result)
    else:
        tapped = tap("Clear")
        shown = labels()
        check("a new @objc action is live", result["status"] == "live" and tapped and "• Buy milk" not in shown
              and "Total: 1" in shown, {"tapped": tapped, "ui": shown, "reload": result.get("status")})

    edit(listing, 'title = "Inbox"', "title = missingName")
    result = cli("reload", listing)
    check("compile error is reported and the app keeps running",
          result["status"] == "compileError" and "Total: 1" in labels(), result)
finally:
    for path, text in originals.items():
        open(path, "w").write(text)

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
