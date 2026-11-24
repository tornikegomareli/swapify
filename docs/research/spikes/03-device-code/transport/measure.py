#!/usr/bin/env python3
"""Transport timings for spike 03, measured on the Mac.

    measure.py devicectl <udid> <bundle id>   copy 100 KB Mac -> app and 300 KB app -> Mac, 5 runs each
    measure.py tcp <host> <port> <label>       against the app's `serve` listener: connect, PING round
                                               trip x50, PUT 100 KB x10, GET 300 KB x10
    measure.py tcp-listen <host> <port> <label>  the same, but the app connects to the Mac (`dial`)
    measure.py tcp-dial <dev host> <dev port> <mac host> <mac port> <label>
                                               the same, asking the running `serve` app to connect back

Each devicectl run is one `xcrun devicectl device copy` process, so it includes process start and
the CoreDevice connection, as a swapify CLI that shells out to devicectl would pay.
"""

import os
import socket
import statistics
import subprocess
import sys
import tempfile
import time

KB = 1024


def stats(seconds):
    ms = [s * 1000 for s in seconds]
    return f"median {statistics.median(ms):.1f} ms (min {min(ms):.1f}, max {max(ms):.1f}, n={len(ms)})"


def devicectl(udid, bid):
    tmp = tempfile.mkdtemp()

    def copy(*args):
        t = time.perf_counter()
        p = subprocess.run(["xcrun", "devicectl", "device", "copy", *args, "--device", udid,
                            "--domain-type", "appDataContainer", "--domain-identifier", bid, "-q"],
                           capture_output=True, text=True)
        dt = time.perf_counter() - t
        if p.returncode:
            sys.exit(f"devicectl failed: {p.stdout}{p.stderr}")
        return dt

    src300 = os.path.join(tmp, "out300k.bin")
    with open(src300, "wb") as f:
        f.write(os.urandom(300 * KB))
    copy("to", "--source", src300, "--destination", "tmp/out300k.bin")

    to_device = []
    for i in range(5):
        src = os.path.join(tmp, f"in100k-{i}.bin")
        with open(src, "wb") as f:
            f.write(os.urandom(100 * KB))  # new content: devicectl skips unchanged files
        to_device.append(copy("to", "--source", src, "--destination", f"tmp/in100k-{i}.bin"))
    from_device = []
    for i in range(5):
        dst = os.path.join(tmp, f"back-{i}.bin")
        from_device.append(copy("from", "--source", "tmp/out300k.bin", "--destination", dst))
        assert os.path.getsize(dst) == 300 * KB, os.path.getsize(dst)
    print(f"devicectl copy to, 100 KB:   {stats(to_device)}")
    print(f"devicectl copy from, 300 KB: {stats(from_device)}")


def tcp(host, port, label):
    t = time.perf_counter()
    s = socket.create_connection((host, port), timeout=15)
    print(f"[{label}] {host}:{port} connect {(time.perf_counter() - t) * 1000:.1f} ms")
    measure(s, label)


def tcp_listen(host, port, label):
    """Waits for the app (`--test dial`) to connect, then measures over that connection."""
    srv = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    srv.settimeout(90)
    print(f"[{label}] listening on {host}:{port}", flush=True)
    s, peer = srv.accept()
    s.settimeout(15)
    print(f"[{label}] app connected from {peer[0]}")
    measure(s, label)


def tcp_dial(dev_host, dev_port, mac_host, mac_port, label):
    """Asks the running `serve` app (over an inbound control connection) to connect to the Mac, then
    measures over the app's outbound connection. Keeps everything in one app launch."""
    srv = socket.socket(socket.AF_INET6 if ":" in mac_host else socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((mac_host, mac_port))
    srv.listen(1)
    srv.settimeout(20)
    ctl = socket.create_connection((dev_host, dev_port), timeout=20)
    ctl.sendall(b"DIAL %s %d\n" % (mac_host.encode(), mac_port))
    reply = ctl.recv(256).decode().strip()
    print(f"[{label}] app -> {mac_host}:{mac_port}: {reply}")
    if not reply.startswith("DIALED"):
        return
    s, peer = srv.accept()
    s.settimeout(15)
    measure(s, label)
    ctl.close()


def measure(s, label):
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    buf = bytearray()
    where = ["", 0]  # phase and iteration, for the stall report

    def read_until(n=None):
        """Reads one line (n=None) or exactly n bytes."""
        while (b"\n" not in buf) if n is None else (len(buf) < n):
            try:
                chunk = s.recv(1 << 16)
            except socket.timeout:
                sys.exit(f"[{label}] STALL in {where[0]} #{where[1]}: no data for {s.gettimeout():.0f} s, "
                         f"{len(buf)} bytes buffered")
            if not chunk:
                sys.exit(f"[{label}] EOF in {where[0]} #{where[1]}")
            buf.extend(chunk)
        end = buf.index(b"\n") + 1 if n is None else n
        out = bytes(buf[:end])
        del buf[:end]
        return out

    rtt, put, get = [], [], []
    data = os.urandom(100 * KB)
    for where[0], count in (("PING", 50), ("PUT 100 KB", 10), ("GET 300 KB", 10)):
        for where[1] in range(count):
            t = time.perf_counter()
            if where[0] == "PING":
                s.sendall(b"PING\n")
                assert read_until() == b"PONG\n"
                rtt.append(time.perf_counter() - t)
            elif where[0] == "PUT 100 KB":
                s.sendall(b"PUT %d\n" % len(data) + data)
                assert read_until().startswith(b"OK")
                put.append(time.perf_counter() - t)
            else:
                s.sendall(b"GET %d\n" % (300 * KB))
                assert len(read_until(300 * KB)) == 300 * KB
                get.append(time.perf_counter() - t)
    s.close()
    print(f"[{label}] PING round trip:          {stats(rtt)}")
    print(f"[{label}] 100 KB Mac -> app (acked): {stats(put)}")
    print(f"[{label}] 300 KB app -> Mac:         {stats(get)}")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "devicectl":
        devicectl(sys.argv[2], sys.argv[3])
    elif mode == "tcp-listen":
        tcp_listen(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    elif mode == "tcp-dial":
        tcp_dial(sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), sys.argv[6])
    else:
        tcp(sys.argv[2], int(sys.argv[3]), sys.argv[4])
