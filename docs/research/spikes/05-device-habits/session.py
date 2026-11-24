#!/usr/bin/env python3
"""Spike 05: end-to-end reloads of swapify's Habits example on a device, with no debugger.

    python3 -I session.py        (after ./build.sh; the phone must be unlocked)

1. Installs Habits, copies SwapifyAgent.dylib into the app's tmp/, and launches the app with
   DYLD_INSERT_LIBRARIES and SWAPIFY_PORT (devicectl --environment-variables). The devicectl
   console process lives as long as the session: it carries the agent's log, and ending it ends
   the app.
2. Talks to the agent over TCP on the CoreDevice tunnel address, read fresh for every connection.
3. Replays the recorded demo on Examples/Habits/Habits/TodayView.swift: v1 (progress ring),
   v2 (cards with buttons), tap Run, v3 (tiles), then a deliberate compile error. Each reload:
   save the file, build the bound patch (patch.py), `put` it, `load`, `refresh`, `snapshot`
   (PNG in the reply), `ui`. Then store1, a logic edit in HabitStore.swift, and a tap that runs
   it. Restores both files at the end.
Writes build/session/<step>.png and .txt, build/session/timings.json, and prints a table.
"""

import base64
import json
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import patch  # noqa: E402

UDID = os.environ.get("UDID", "00008160-000A51191083400A")
BID = "dev.swapify.spike.device.habits"
PORT = 7791
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
SOURCES = os.path.join(REPO, "Examples/Habits/Habits")
OUT = os.path.join(HERE, "build", "session")


def devicectl(*args):
    p = subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(f"devicectl {' '.join(args[:3])} failed:\n{p.stdout}{p.stderr}")
    return p.stdout


def tunnel_address():
    for line in devicectl("device", "info", "details", "--device", UDID).splitlines():
        if "Tunnel IP Address:" in line:
            return line.split(":", 1)[1].strip()
    raise RuntimeError("no CoreDevice tunnel address")


class Agent:
    def __init__(self):
        self.connect()

    def connect(self):
        t = time.perf_counter()
        self.address = tunnel_address()
        self.sock = socket.create_connection((self.address, PORT), timeout=30)
        self.io = self.sock.makefile("rwb")
        self.connect_ms = (time.perf_counter() - t) * 1000

    def call(self, line, payload=b""):
        for attempt in (1, 2):  # the tunnel can be re-created under us: reconnect once
            try:
                self.io.write(line.encode() + b"\n" + payload)
                self.io.flush()
                reply = self.io.readline()
                if reply:
                    return json.loads(reply)
                raise OSError("connection closed")
            except OSError as error:
                if attempt == 2:
                    raise
                print(f"   ({line.split()[0]}: {error}; reconnecting)")
                self.connect()


def launch():
    print(devicectl("device", "install", "app", "--device", UDID,
                    os.path.join(patch.APP)).splitlines()[0])
    copy = os.path.join(OUT, "copy.json")
    devicectl("device", "copy", "to", "--device", UDID, "--source", os.path.join(HERE, "build/SwapifyAgent.dylib"),
              "--destination", "tmp/SwapifyAgent.dylib", "--domain-type", "appDataContainer",
              "--domain-identifier", BID, "--json-output", copy, "-q")
    agent_path = json.load(open(copy))["result"]["destination"].removeprefix("file://")
    environment = json.dumps({"DYLD_INSERT_LIBRARIES": agent_path, "SWAPIFY_PORT": str(PORT)})
    log = open(os.path.join(OUT, "app.log"), "w")
    t = time.perf_counter()
    console = subprocess.Popen(["xcrun", "devicectl", "device", "process", "launch", "--device", UDID, "--console",
                                "--terminate-existing", "--environment-variables", environment, BID],
                               stdout=log, stderr=subprocess.STDOUT)
    for _ in range(120):
        text = open(os.path.join(OUT, "app.log")).read()
        if "[swapify] listening" in text or "ERROR" in text or console.poll() is not None:
            break
        time.sleep(0.25)
    print(f"launch with DYLD_INSERT_LIBRARIES={agent_path}: {(time.perf_counter() - t) * 1000:.0f} ms")
    print("   " + "\n   ".join(l for l in text.splitlines() if l.strip()))
    if "[swapify] listening" not in text:
        raise RuntimeError("the agent did not start")
    return console


def capture(agent, name):
    """Screenshot and visible text, saved under build/session/<name>.*. Returns the text and times."""
    t = time.perf_counter()
    shot = agent.call("snapshot")
    for _ in range(20):  # the app is foreground but inactive (a system overlay): wait for it, 10 s at most
        if shot.get("ok") or shot.get("error") != "no visible window":
            break
        print(f"   (no visible window: applicationState {shot.get('applicationState')}, "
              f"scenes {shot.get('sceneStates')}; waiting)")
        time.sleep(0.5)
        shot = agent.call("snapshot")
    shot_ms = (time.perf_counter() - t) * 1000
    if not shot.get("ok"):
        raise RuntimeError(f"snapshot: {shot}")
    png = base64.b64decode(shot["png"])
    open(os.path.join(OUT, name + ".png"), "wb").write(png)
    t = time.perf_counter()
    ui = agent.call("ui")
    for _ in range(4):  # right after launch the accessibility tree can still be empty
        if ui.get("elements"):
            break
        time.sleep(0.5)
        ui = agent.call("ui")
    ui_ms = (time.perf_counter() - t) * 1000
    text = " | ".join(e["label"] + (f" = {e['value']}" if e["value"] else "") for e in ui.get("elements", []))
    open(os.path.join(OUT, name + ".txt"), "w").write(text + "\n")
    return text, [("screenshot to the Mac", shot_ms, f"{len(png)} bytes, rendered in {shot['ms']:.0f} ms"),
                  ("visible text", ui_ms, f"{len(ui.get('elements', []))} elements")]


def reload(agent, edit, name, timings, file="TodayView.swift"):
    source = os.path.join(SOURCES, file)
    content = open(os.path.join(HERE, "edits", edit, file)).read()
    open(source, "w").write(content)
    t0 = time.perf_counter()  # the file is saved
    steps = []
    try:
        dylib, built, report = patch.build(source, os.path.join(OUT, f"patch-{name}"))
    except patch.CompileError as error:
        ms = (time.perf_counter() - t0) * 1000
        print(f"== {name} ({edit}): compile error reported after {ms:.0f} ms, nothing sent:\n   {error}")
        timings.append({"step": name, "edit": edit, "compile_error": str(error), "ms": ms})
        return None
    steps += [(step, s * 1000, "") for step, s in built]
    data = open(dylib, "rb").read()
    t = time.perf_counter()
    put = agent.call(f"put {name}-{int(time.time() * 1000)}.dylib {len(data)}", data)
    steps.append(("send patch", (time.perf_counter() - t) * 1000, f"{len(data)} bytes"))
    t = time.perf_counter()
    load = agent.call(f"load {put['path']}")
    steps.append(("load", (time.perf_counter() - t) * 1000,
                  f"dlopen {load.get('dlopenMs', 0):.1f} ms, roots {load.get('patchMs', 0):.2f} ms, "
                  f"replaced {load.get('replaced')}, added {load.get('added')}" if load.get("ok") else str(load)))
    if not load.get("ok"):
        raise RuntimeError(f"load failed: {load}")
    t = time.perf_counter()
    refresh = agent.call("refresh")
    steps.append(("refresh", (time.perf_counter() - t) * 1000, f"{refresh.get('hosts')} hosting views"))
    text, captured = capture(agent, name)
    steps += captured
    total = (time.perf_counter() - t0) * 1000
    print(f"== {name} ({edit}): {total:.0f} ms from save to screenshot and text on the Mac  [{report.splitlines()[0]}]")
    for step, ms, note in steps:
        print(f"   {step:<22} {ms:7.0f} ms  {note}")
    print(f"   seen: {text}")
    timings.append({"step": name, "edit": edit, "ms": total, "steps": steps, "seen": text})
    return text


def main():
    os.makedirs(OUT, exist_ok=True)
    originals = {f: open(os.path.join(SOURCES, f)).read() for f in ("TodayView.swift", "HabitStore.swift")}
    console, timings = None, []
    try:
        console = launch()
        agent = Agent()
        ping = agent.call("ping")
        print(f"connected to [{agent.address}]:{PORT} in {agent.connect_ms:.0f} ms; ping: {ping}")
        text, _ = capture(agent, "0-launch")
        print(f"== 0-launch: {text}")
        reload(agent, "v1", "1-v1", timings)
        reload(agent, "v2", "2-v2", timings)
        tap = agent.call("tap Run")
        print(f"== tap Run: {tap}")
        time.sleep(0.6)  # the button's change is animated; a screenshot taken at once shows the old state
        text, _ = capture(agent, "3-tap-run")
        print(f"   seen: {text}")
        after_v3 = reload(agent, "v3", "4-v3", timings)
        print(f"== state kept after v3: Run is done = {'Run = 12 days, done' in (after_v3 or '')}")
        reload(agent, "error", "5-error", timings)
        text, _ = capture(agent, "5-after-error")
        print(f"== after the compile error the screen text is unchanged: {text == after_v3}")
        # The demo's last beat: a logic edit in another file, run by an old call site (v3's button).
        open(os.path.join(SOURCES, "TodayView.swift"), "w").write(open(os.path.join(HERE, "edits/v3/TodayView.swift")).read())
        reload(agent, "store1", "6-store1", timings, file="HabitStore.swift")
        tap = agent.call("tap Meditate")
        print(f"== tap Meditate: {tap}")
        time.sleep(0.6)
        text, _ = capture(agent, "7-tap-meditate")
        print(f"   seen: {text}")
        print(f"== the edited toggle ran (streak 27 -> 28): {'Meditate = 28 days, done' in text}")
        print(f"== final ping: {agent.call('ping')}")
    finally:
        for f, text in originals.items():
            open(os.path.join(SOURCES, f), "w").write(text)
        json.dump(timings, open(os.path.join(OUT, "timings.json"), "w"), indent=1)
        if console:
            console.terminate()
            console.wait(timeout=30)


if __name__ == "__main__":
    main()
