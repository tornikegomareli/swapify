#!/usr/bin/env python3
"""Runs spike 03 tests on the device, each in its own launch, without and with LLDB attached.

    python3 -I run.py [--dbg | --nodbg | --both] <test> [<test> ...]
    python3 -I run.py --prepare-dlopen      # copy the plugin into the app's data container

Tests (App/Tests.c): 1a 1b 1c 1d 1e 2cave 2region-dbg 2region-app 2region-notouch 2region-big
                     3tmp 3lib 3dylib 3adhoc 3otherteam 3bundle 3patch
With --dbg the app is launched with `devicectl ... --start-stopped` and lldb/spike_lldb.py attaches
with `device process attach -p <pid>` before any app code runs, as Xcode does. A `+wait` suffix
(for example `2region-app+wait`) launches normally and attaches to the running app instead.
Logs: build/logs/<test>.<dbg|nodbg>.app.log (app stdout via --console) and .lldb.log.
"""

import json
import os
import subprocess
import sys
import time

UDID = os.environ.get("UDID", "00008160-000A51191083400A")
BID = "dev.swapify.spike.device"
HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(HERE, "build", "logs")


def devicectl(*args, timeout=120):
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True, timeout=timeout)


def coredevice_id():
    """LLDB's `device select` takes the CoreDevice identifier; with the UDID it fails silently."""
    path = os.path.join(LOGS, "devices.json")
    devicectl("list", "devices", "--json-output", path, "-q")
    for d in json.load(open(path))["result"]["devices"]:
        if d.get("hardwareProperties", {}).get("udid") == UDID:
            return d["identifier"]
    return UDID


def spike_pids():
    path = os.path.join(LOGS, "procs.json")
    devicectl("device", "info", "processes", "--device", UDID, "--json-output", path, "-q")
    return {p["processIdentifier"] for p in json.load(open(path))["result"]["runningProcesses"]
            if "/Spike.app/Spike" in p.get("executable", "")}


def crash_reports():
    """Names of this app's crash reports on the device (only Spike-* files are listed)."""
    path = os.path.join(LOGS, "crashes.json")
    devicectl("device", "info", "files", "--device", UDID, "--domain-type", "systemCrashLogs", "--search", "Spike",
              "--json-output", path, "-q")
    try:
        return {f["name"] for f in json.load(open(path))["result"]["files"] if f["name"].startswith("Spike-")}
    except (KeyError, ValueError):
        return set()


def summarize_crash(name, dest):
    """Copies one Spike crash report and returns its exception and termination fields."""
    devicectl("device", "copy", "from", "--device", UDID, "--domain-type", "systemCrashLogs", "--source", name,
              "--destination", dest, "-q")
    try:
        report = json.loads(open(dest).read().split("\n", 1)[1])
    except (OSError, IndexError, ValueError):
        return f"crash report {name}: could not read"
    e, t = report.get("exception", {}), report.get("termination", {})
    return (f"CRASH REPORT {name}: {e.get('type')} ({e.get('signal')}) {e.get('subtype', '')} | termination "
            f"namespace={t.get('namespace')} code={t.get('code')} indicator={t.get('indicator')} | "
            f"codeSigningMonitor={report.get('codeSigningMonitor')}")


def prepare_dlopen():
    for src, dst in [("build/SpikePlugin.framework", "tmp/SpikePlugin.framework"),
                     ("build/SpikePlugin.framework", "Library/SpikePlugin.framework"),
                     ("build/libspikeplugin.dylib", "tmp/libspikeplugin.dylib"),
                     ("build/libspikeplugin-adhoc.dylib", "tmp/libspikeplugin-adhoc.dylib"),
                     ("build/libspikeplugin-otherteam.dylib", "tmp/libspikeplugin-otherteam.dylib")]:
        if not os.path.exists(os.path.join(HERE, src)):
            print(f"skip {src}: not built")
            continue
        r = devicectl("device", "copy", "to", "--device", UDID, "--source", os.path.join(HERE, src),
                      "--destination", dst, "--domain-type", "appDataContainer", "--domain-identifier", BID, "-q")
        print(f"copy {src} -> {dst}: rc={r.returncode} {r.stderr.strip()}")


def launch(test, debugger):
    tag = "dbg" if debugger else "nodbg"
    app_log = os.path.join(LOGS, f"{test}.{tag}.app.log")
    lldb_log = os.path.join(LOGS, f"{test}.{tag}.lldb.log")
    args = ["xcrun", "devicectl", "device", "process", "launch", "--device", UDID, "--console",
            "--terminate-existing"]
    if debugger and not test.endswith("+wait"):  # `+wait` tests: LLDB attaches to the running app
        args.append("--start-stopped")
    args += [BID, "--", "--test", test]
    before = crash_reports()
    old_pids = spike_pids() if debugger else set()  # an exiting instance can still be listed
    t0 = time.time()
    with open(app_log, "w") as f:
        app = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT)
    if debugger:
        if test.endswith("+wait"):
            # Stopping the app during its launch trips the FrontBoard launch watchdog (0x8badf00d),
            # so attach only after the app runs and has had time to finish launching.
            for _ in range(60):
                if "waiting for a debugger" in open(app_log, errors="replace").read():
                    break
                time.sleep(0.5)
            time.sleep(10)
        pid = None
        for _ in range(60):
            new = spike_pids() - old_pids
            if new:
                pid = max(new)
                break
            time.sleep(0.5)
        with open(lldb_log, "w") as f:
            if not pid:
                f.write("no pid found\n")
            else:
                try:
                    subprocess.run(["xcrun", "lldb", "-b",
                                    "-o", f"command script import {HERE}/lldb/spike_lldb.py",
                                    "-o", f"spike_drive {coredevice_id()} {pid}"],
                                   stdout=f, stderr=subprocess.STDOUT, timeout=300)
                except subprocess.TimeoutExpired:
                    f.write("LLDB TIMEOUT after 300 s\n")
    try:
        app.wait(timeout=120)
    except subprocess.TimeoutExpired:
        app.terminate()
        with open(app_log, "a") as f:
            f.write("RUNNER: devicectl did not exit within 120 s\n")
    print(f"===== {test} [{'with LLDB' if debugger else 'no debugger'}] ({time.time() - t0:.1f} s)")
    for path in [lldb_log, app_log] if debugger else [app_log]:
        for line in open(path, errors="replace"):
            line = line.rstrip()
            if line and not line.startswith(("Gathering", "Acquired", "Enabling", "Waiting for the")):
                print("   ", line)
    time.sleep(2)  # ReportCrash writes the report shortly after the kill
    os.makedirs(os.path.join(HERE, "build", "crashes"), exist_ok=True)
    for name in sorted(crash_reports() - before):
        summary = summarize_crash(name, os.path.join(HERE, "build", "crashes", f"{test}.{tag}.{name}"))
        print("   ", summary)
        with open(app_log, "a") as f:
            f.write(summary + "\n")


def main():
    os.makedirs(LOGS, exist_ok=True)
    args = sys.argv[1:]
    if args == ["--prepare-dlopen"]:
        prepare_dlopen()
        return
    modes = [False, True]
    if args and args[0] in ("--dbg", "--nodbg", "--both"):
        modes = {"--dbg": [True], "--nodbg": [False], "--both": [False, True]}[args.pop(0)]
    for test in args:
        for debugger in modes:
            launch(test, debugger)


if __name__ == "__main__":
    main()
