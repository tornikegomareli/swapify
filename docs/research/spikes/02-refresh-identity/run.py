"""Launches Demo.app with HotAgent, then screenshots: before, after load, after refresh.

Usage: python3 -I run.py <device-set> <udid>
"""
import os
import socket
import subprocess
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
build = os.path.join(here, "build")
device_set, udid = sys.argv[1], sys.argv[2]
simctl = ["xcrun", "simctl", "--set", device_set]


def send(command):
    with socket.create_connection(("127.0.0.1", 8899)) as s:
        s.sendall((command + "\n").encode())
        return s.makefile().readline().strip()


def screenshot(name):
    path = os.path.join(build, name + ".png")
    subprocess.run(simctl + ["io", udid, "screenshot", path], check=True, capture_output=True)
    print("screenshot", path)


subprocess.run(simctl + ["install", udid, os.path.join(build, "Demo.app")], check=True)
env = dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=os.path.join(build, "HotAgent.dylib"))
log = open(os.path.join(build, "console.log"), "w")
subprocess.Popen(simctl + ["launch", "--terminate-running-process", "--console-pty", udid,
                           "dev.hotreload.demo"], env=env, stdout=log, stderr=log)
time.sleep(3)
screenshot("1-before")
print("load", send("load " + os.path.join(build, "patch", "patch_v2.dylib")))
time.sleep(1)
screenshot("2-after-load")
print("refresh", send("refresh"))
time.sleep(1)
screenshot("3-after-refresh")
