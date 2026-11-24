# Spike 03: running new code on a real iPhone

Question: on a device, how can swapify get an edited file's code into the running app?

Measured on 2026-11-24 on "Doomile", iPhone19,4, iOS 27.2 (24B91020), Developer Mode on, with Xcode 27.2 (27B52) and lldb-2103.0.34.407. The phone was connected over Wi-Fi only: CoreDevice transport `localNetwork`, tunnel over TCP. The Mac was on the phone's Personal Hotspot (phone 172.20.10.1, Mac 172.20.10.11). No cable was used.

The app was built with automatic signing for team 539293JFA3 ("Apple Development: … (PVRMHF9AJP)", wildcard team profile). Its entitlements were `application-identifier`, `com.apple.developer.team-identifier`, and `get-task-allow`.

## Answers

- The process cannot make memory executable by itself, with or without a debugger attached (test 1).
- Code that LLDB writes runs. That holds for the signed `__TEXT`, a `dlopen`ed framework, and anonymous RX pages. After LLDB has written once to a 16 KB page, the app can rewrite that page through its own RW alias and run the result. This kept working after LLDB detached (test 2).
- `dlopen` from the data container works if the dylib is signed by the app's own team. An ad hoc signature and another team's signature are both rejected. A debugger changes nothing here (test 3).
- A TCP connection to the app takes 9 to 33 ms per round trip. A `devicectl copy` takes about 0.75 s of fixed cost (test 4).

## Code signing state

| | Without debugger | With LLDB attached | After LLDB detached |
|---|---|---|---|
| `csops` flags | `0x22003305` | `0x32003005` | `0x32003005` |
| `CS_DEBUGGED` | 0 | 1 | 1 (stays set) |
| `CS_HARD`, `CS_KILL` | 1, 1 | 0, 0 | 0, 0 |
| `P_TRACED` | 0 | 1 | 0 |

Every crash report has `"codeSigningMonitor": 2`. The M4 Max Mac used for the build also writes `2` and has `kern.sptm.boot_timestamps.txm_bootstrap` set, so `2` means TXM. That is an inference: the app gets `EPERM` for `kern.sptm.*` and `vm.cs_defer_to_csm`. The VM page size is 16384.

## Results

"With LLDB" means `devicectl device process launch --start-stopped`, then `device process attach -p <pid>` before any app code runs, as Xcode does. Each test ran in its own launch. When a process was killed without a debugger, `devicectl` printed "terminated with the exit code 0". The cause in the table comes from the crash report.

### 1. Code the process writes (`mov w0, #42; ret`)

| Method | Without debugger | With LLDB attached |
|---|---|---|
| 1a `mmap` RW, `mprotect` RX | `mprotect` returns 0, but the page becomes `r--`, max `rw-`. Call: killed, `EXC_BAD_ACCESS (SIGKILL) KERN_PROTECTION_FAILURE`, termination `CODESIGNING` code 2 "Invalid Page" | Same `r--`/`rw-`. Call: `EXC_BAD_ACCESS (code=2)` |
| 1b `mmap` RWX `MAP_JIT` | `EPERM` ("Operation not permitted"). `pthread_jit_write_protect_np` is absent (`dlsym` NULL). `pthread_jit_write_protect_supported_np()` returns 1 | `EPERM` |
| 1c `vm_protect(VM_PROT_COPY)` on a signed `__TEXT` page | `RW\|COPY` succeeds, page `rw-`, max `rw-`. Write works. `vm_protect(RX)` returns `KERN_PROTECTION_FAILURE` (2). Call: killed, `CODESIGNING` "Invalid Page" | Same. Call: `EXC_BAD_ACCESS (code=2)` |
| 1d `mmap` RWX without `MAP_JIT` | Mapping is `rw-`, max `rwx`. Call: killed, `CODESIGNING` "Invalid Page" | `EXC_BAD_ACCESS (code=2)` |
| 1e `mmap` RX plus an RW alias from `vm_remap` | Alias `rw-` and RX view `r-x` both succeed. Call: killed, `CODESIGNING` "Invalid Page" | `EXC_BAD_ACCESS (code=50)` (`KERN_CODESIGN_ERROR`) on an `r-x` page |

With LLDB attached, continuing after the exception faulted again at the same pc. The driver killed the process after three faults.

### 2. Code the debugger writes (needs LLDB, so there is no "without" column)

| Test | With LLDB attached | After LLDB detached |
|---|---|---|
| 2a `memory write -s 4 <cave> 0x52800540 0xd65f03c0` into a 64 KB `brk` cave in `__TEXT` | returns 42 | returns 42 |
| 2b `memory write -i` of 32 KB (`mov w0, #0`, 8190 × `add w0, w0, #1`, `ret`) across 3 pages of the cave | returns 8190 | returns 8190 |
| 2region-dbg: `SBProcess.AllocateMemory(64 KB, rx)`, LLDB rewrites 1 byte per page, app writes through its own `vm_remap` RW alias | 42, rewrite 43, 8 KB on page 2: 2046 | new page: 44, rewrite: 45 |
| 2region-app: the app maps RX itself, LLDB rewrites 1 byte per page | 42, 43, 2046 | 44, 45 |
| 2region-notouch (control): app maps RX, LLDB attached but writes nothing | `EXC_BAD_ACCESS (code=50)` on the first call | not reached |
| 2region-big: 16 MB from `AllocateMemory`, LLDB writes zeros in 1 MB writes | 42, 43, 2046 | 44, 45, last page: 46 |
| 3patch: `dlopen` the framework from `tmp/`, then LLDB writes `mov w0, #43; ret` over `spike_plugin_value` | returns 43 | returns 43 |

The write by the debugger makes the page executable. `CS_DEBUGGED` alone does not, as the control shows. In every run, the permission stayed after the detach, for pages LLDB had already written. Pages that LLDB never wrote never ran.

### 3. `dlopen`

| Library | Without debugger | With LLDB attached |
|---|---|---|
| `SpikePlugin.framework` in `tmp/`, same team | ok, returns 42 | ok, 42 |
| The same framework in `Library/` | ok, 42 | ok, 42 |
| Plain dylib in `tmp/`, same team | ok, 42 | ok, 42 |
| Plain dylib in `tmp/`, ad hoc (`codesign -s -`) | `code signature invalid in <UUID> '<path>' (errno=1)` | same |
| Plain dylib in `tmp/`, Apple Development cert of team 26C8QYLY6P | `code signature in <UUID> '<path>' not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs` | same |
| Framework embedded in the app (control) | ok, 42 | ok, 42 |

The plugins were copied with `devicectl device copy to --domain-type appDataContainer`. The forum report that iOS 18 refuses libraries outside the bundle does not reproduce here, on a development-signed app with Developer Mode on. A distribution-signed app was not tested.

### 4. Transport

`devicectl device copy`, 5 runs each. Each run is one `xcrun devicectl` process:

| Copy | Median | Range |
|---|---|---|
| 100 KB, Mac to app container | 802 ms | 753 to 1394 ms |
| 300 KB, app container to Mac | 696 ms | 658 to 780 ms |
| 16 bytes, Mac to app container | | 700 to 790 ms |

TCP between the Mac and the app, 3 runs within one app launch. Each cell gives the range of the per-run medians: 50 round trips, 10 × 100 KB, 10 × 300 KB.

| Path | Connect | Small message round trip | 100 KB Mac to app (acknowledged) | 300 KB app to Mac |
|---|---|---|---|---|
| Inbound (Mac connects to the app's listener), CoreDevice tunnel | 14 to 36 ms | 26 to 33 ms | 26 to 43 ms | 40 to 67 ms |
| Inbound, Wi-Fi (phone 172.20.10.1) | 24 to 54 ms | 9 to 12 ms | 21 to 46 ms | 36 to 60 ms |
| Outbound (app connects to the Mac), CoreDevice tunnel | 19 to 21 ms | 21 to 32 ms | 26 to 39 ms | 48 to 51 ms |
| Outbound, Wi-Fi (Mac 172.20.10.11) | fails at once: `errno=65 (No route to host)`, 3 of 3 | | | |
| `iproxy` (usbmuxd) | `idevice_id -l` and `-n` list no device; `iproxy` resets every connection | | | |

The outbound Wi-Fi failure matches local network privacy. TN3179 says an outgoing TCP connection to a local network address needs the Local Network privilege, and that VPN-style interfaces such as the tunnel are not a local network. The app never had that privilege, and nobody answered an alert. Accepting incoming connections needs no privilege, which matches the inbound rows.

The tunnel had eight different addresses during the session (`fdb2:…`, `fdd9:…`, `fd83:…`, `fd8d:…`, `fda7:…`, `fd7c:…`, `fde3:…`, `fd27:…`), so read it before every connection: `devicectl device info details` prints it as "Tunnel IP Address".

### Debugger costs (over Wi-Fi)

| Step | Time |
|---|---|
| `device process attach` to a process launched with `--start-stopped` | 2.6 to 3.1 s (once 4.5 s) |
| `memory write`, 8 bytes | 65 to 211 ms |
| `memory write -i`, 32 KB | 159 ms |
| Rewrite 1 byte per page (read and write), 4 pages | 395 to 450 ms |
| Write zeros over 16 MB in 1 MB writes | 14.2 s (about 1.2 MB/s) |
| App calls a breakpointed hook, LLDB writes 8 bytes, the app continues | 782 ms round trip seen by the app |
| `SBProcess.Detach()` | 39 to 111 ms |

## Problems seen

- The phone was locked at the start and locked twice more. While it is locked, SpringBoard refuses every launch: "The request was denied by service delegate (SBMainWorkspace) for reason: Locked". `lldb device select` also refuses ("Device needs to be unlocked."). `devicectl copy` and `install` work while the phone is locked.
- `lldb device select` needs the CoreDevice identifier (`devicectl list devices`, field `identifier`). With the UDID it fails without an error message. `device select` and `device process attach` return `eReturnStatusStarted` and finish about 3 s later, so a script has to wait for the process state `stopped`.
- Late attach, to an app that was not launched stopped, did not work. In the first try, LLDB stopped the app during its launch and FrontBoard killed it with `0x8badf00d`. In the second try, the attach took 11.7 s and then LLDB crashed (SIGSEGV in `ProcessGDBRemote::WillPublicStop`). The attach did reach the kernel, because the app later showed `CS_DEBUGGED=1`. Two attempts failed, so this line stopped there.
- With the screen off, the first inbound TCP test hung. Connections completed, but `accept()` never returned, and LLDB showed the listener thread blocked in `__accept`. With the screen kept on (`isIdleTimerDisabled` while the app is frontmost), inbound worked in every run. The likely cause is a suspended app. That is an inference, not a measurement.
- Two early outbound-tunnel runs stalled in the 300 KB app-to-Mac phase (no data for 15 s). The cause is unknown. The final 3 runs did not stall.
- One launch (1b without debugger) printed nothing for 120 s. A rerun was normal.

## Not tested

- A USB cable: the phone was not plugged in, so every number is Wi-Fi.
- Distribution signing, and Developer Mode off.
- An arm64e app, where function pointers into new code need PAC signing. This app is arm64.
- A real swapify patch: a Swift dylib linked `-undefined dynamic_lookup` against the app. Test 3 used a C function with no undefined symbols.
- The Wi-Fi outbound path with the Local Network privilege granted. That needs someone to tap Allow on the phone.

## Files

- `project.yml`: xcodegen spec. App `dev.swapify.spike.device`, plus `SpikePlugin.framework`, embedded but not linked.
- `App/Tests.c`: every test (`--test <name>`). `App/Cave.s`: the code caves. `App/SpikeApp.swift`: the app shell.
- `lldb/spike_lldb.py`: the LLDB driver. It attaches, puts a breakpoint on `spike_hook`, and serves the app's requests.
- `run.py`: runs one test per launch, without and with LLDB, and pulls the app's crash reports.
- `transport/measure.py`, `transport/tcp.sh`: the transport measurements.
- `build.sh` builds everything into `build/`. `run.sh` reruns every measurement in this file and uninstalls the app at the end. The phone must stay unlocked. Logs go to `build/logs/`, crash reports to `build/crashes/`.
