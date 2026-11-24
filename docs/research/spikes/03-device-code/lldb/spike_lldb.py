"""LLDB side of spike 03. Load inside LLDB:

    (lldb) command script import lldb/spike_lldb.py
    (lldb) spike_drive <CoreDevice identifier> <pid>

Attaches to the app with `device process attach`, sets a breakpoint on spike_hook, and serves the
app's requests (App/Tests.c, spike_req): write code with `memory write`, allocate an RX region with
SBProcess.AllocateMemory, rewrite one byte per 16 KB page or zero a whole region, or detach.
Prints `LLDB ...` lines.
"""

import os
import struct
import tempfile
import time

import lldb

PAGE = 16384
HOOK_WRITE_RET, HOOK_WRITE_CHAIN, HOOK_ALLOC_RX, HOOK_TOUCH, HOOK_DETACH = 1, 2, 3, 4, 5
OP_RET = 0xD65F03C0
OP_ADD1 = 0x11000400


def movz_w0(imm):
    return 0x52800000 | (imm << 5)


def log(msg):
    print(f"LLDB {time.strftime('%H:%M:%S')} {msg}", flush=True)


def run(ci, text):
    res = lldb.SBCommandReturnObject()
    ci.HandleCommand(text, res)
    out = ((res.GetOutput() or "") + (res.GetError() or "")).strip()
    # `device select` and `device process attach` return eReturnStatusStarted and finish later.
    ok = res.Succeeded() or res.GetStatus() == lldb.eReturnStatusStarted
    log(f"(lldb) {text} -> {'ok' if ok else 'FAILED'} (status {res.GetStatus()}){': ' + out if out else ''}")
    return ok


def symbol_address(target, name):
    found = target.FindSymbols(name)
    for i in range(found.GetSize()):
        addr = found.GetContextAtIndex(i).GetSymbol().GetStartAddress().GetLoadAddress(target)
        if addr != lldb.LLDB_INVALID_ADDRESS:
            return addr
    return None


def touch_pages(process, addr, size):
    """Rewrites the first byte of every page with its current value, through debugserver."""
    ok = True
    t0 = time.time()
    for off in range(0, size, PAGE):
        err = lldb.SBError()
        byte = process.ReadMemory(addr + off, 1, err)
        if not err.Success():
            log(f"read 0x{addr + off:x} failed: {err}")
            ok = False
            continue
        written = process.WriteMemory(addr + off, byte, err)
        if not err.Success() or written != 1:
            log(f"write 0x{addr + off:x} failed: {err}")
            ok = False
    log(f"touched {size // PAGE} pages at 0x{addr:x} in {(time.time() - t0) * 1000:.0f} ms, ok={ok}")
    return ok


def fill_zero(process, addr, size, chunk=1 << 20):
    """Writes zeros over the whole range, 1 MB per SBProcess.WriteMemory call."""
    ok = True
    t0 = time.time()
    zeros = bytes(chunk)
    for off in range(0, size, chunk):
        err = lldb.SBError()
        n = min(chunk, size - off)
        written = process.WriteMemory(addr + off, zeros[:n], err)
        if not err.Success() or written != n:
            log(f"write 0x{addr + off:x}+{n} failed: {err} (wrote {written})")
            ok = False
            break
    log(f"filled {size} bytes at 0x{addr:x} in {(time.time() - t0) * 1000:.0f} ms, ok={ok}")
    return ok


def prepare(process, addr, size, mode):
    return fill_zero(process, addr, size) if mode == 2 else touch_pages(process, addr, size)


def handle(ci, process, req):
    """Serves one spike_hook request. Returns True if the app asked us to detach."""
    err = lldb.SBError()
    raw = process.ReadMemory(req, 48, err)
    cmd, addr, length, arg, _, _ = struct.unpack("<6Q", raw)
    status, result, detach = 2, 0, False
    t0 = time.time()
    if cmd == HOOK_WRITE_RET:
        ok = run(ci, f"memory write -s 4 0x{addr:x} 0x{movz_w0(arg):x} 0x{OP_RET:x}")
        status = 1 if ok else 2
    elif cmd == HOOK_WRITE_CHAIN:
        count = length // 4
        words = [movz_w0(0)] + [OP_ADD1] * (count - 2) + [OP_RET]
        fd, path = tempfile.mkstemp(suffix=".bin")
        with os.fdopen(fd, "wb") as f:
            f.write(struct.pack(f"<{count}I", *words))
        ok = run(ci, f"memory write -i {path} 0x{addr:x}")
        os.unlink(path)
        status = 1 if ok else 2
    elif cmd == HOOK_ALLOC_RX:
        perms = lldb.ePermissionsReadable | lldb.ePermissionsExecutable
        result = process.AllocateMemory(length, perms, err)
        log(f"AllocateMemory({length}, rx) -> 0x{result:x} {err}")
        status = 1 if err.Success() and prepare(process, result, length, arg) else 2
    elif cmd == HOOK_TOUCH:
        status = 1 if prepare(process, addr, length, arg) else 2
    elif cmd == HOOK_DETACH:
        status, detach = 1, True
    log(f"request cmd={cmd} addr=0x{addr:x} len={length} -> status={status} in {(time.time() - t0) * 1000:.0f} ms")
    process.WriteMemory(req + 32, struct.pack("<QQ", result, status), err)
    return detach


def stopped_thread(process):
    for thread in process:
        if thread.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
            return thread
    return process.GetSelectedThread()


def drive(debugger, command, exe_ctx, result, internal_dict):
    device, pid = command.split()[:2]  # device: the CoreDevice identifier, not the UDID
    debugger.SetAsync(False)
    ci = debugger.GetCommandInterpreter()
    if not run(ci, f"device select {device}"):
        return
    t0 = time.time()
    if not run(ci, f"device process attach -p {pid}"):
        return
    for _ in range(240):  # the attach completes asynchronously: state goes connected -> stopped
        target = debugger.GetSelectedTarget()
        process = target.GetProcess()
        if process.GetState() == lldb.eStateStopped and target.GetNumModules() > 1:
            break
        time.sleep(0.25)
    else:
        log(f"attach did not finish: state={lldb.SBDebugger.StateAsCString(process.GetState())}")
        return
    log(f"attach took {time.time() - t0:.1f} s; stopped at pc=0x{process.GetSelectedThread().GetFrameAtIndex(0).GetPC():x}")
    req = symbol_address(target, "spike_req")
    bp = target.BreakpointCreateByName("spike_hook")
    log(f"spike_req=0x{req or 0:x} spike_hook breakpoint locations={bp.GetNumLocations()}")
    exceptions = 0
    while True:
        process.Continue()
        state = process.GetState()
        if state == lldb.eStateExited:
            log(f"process exited: status={process.GetExitStatus()} description={process.GetExitDescription()}")
            return
        if state != lldb.eStateStopped:
            log(f"process state: {lldb.SBDebugger.StateAsCString(state)}")
            return
        thread = stopped_thread(process)
        reason = thread.GetStopReason()
        if reason == lldb.eStopReasonBreakpoint and thread.GetStopReasonDataAtIndex(0) == bp.GetID():
            if handle(ci, process, req):
                t0 = time.time()
                err = process.Detach()
                log(f"detach -> {err} in {(time.time() - t0) * 1000:.0f} ms")
                return
            continue
        frame = thread.GetFrameAtIndex(0)
        log(f"STOP reason={reason} description={thread.GetStopDescription(256)} pc=0x{frame.GetPC():x}")
        exceptions += 1
        if exceptions >= 3:
            log("same exception 3 times, killing the process")
            process.Kill()
            return


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.drive spike_drive")
