// Low-level probes for spike 03. One test per launch (`--test <name>`), so a kill ends one test only.
// Every line starts with `SPIKE <test>`; run.sh reads them from `devicectl ... --console`.
#include "Tests.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <ifaddrs.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <os/log.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define PAGE 16384u
#define OP_MOVZ_W0(imm) (0x52800000u | ((uint32_t)(imm) << 5)) // mov w0, #imm
#define OP_RET 0xd65f03c0u                                    // ret
#define OP_ADD1 0x11000400u                                   // add w0, w0, #1

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern char spike_cave[];  // Cave.s: 64 KB of `brk #1`, page aligned, in __TEXT,__text
extern char spike_cave2[]; // Cave.s: 16 KB of `brk #2`

// ---------------------------------------------------------------------------------------------
// Output

static const char *g_test = "?";
static os_log_t g_log;

static void say(const char *fmt, ...) {
    char msg[1024], line[1200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    int n = snprintf(line, sizeof line, "SPIKE %s %s\n", g_test, msg);
    write(STDOUT_FILENO, line, (size_t)n);
    os_log(g_log, "SPIKE %{public}s %{public}s", g_test, msg);
}

static void on_signal(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    const char *name = sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" : sig == SIGILL ? "SIGILL"
                     : sig == SIGTRAP ? "SIGTRAP" : "?";
    char line[256];
    int n = snprintf(line, sizeof line, "SPIKE %s CRASH signal=%d (%s) si_code=%d si_addr=%p\n",
                     g_test, sig, name, si->si_code, si->si_addr);
    write(STDOUT_FILENO, line, (size_t)n);
    _exit(100 + sig);
}

static void install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}

// ---------------------------------------------------------------------------------------------
// Process state

static uint32_t cs_flags(void) {
    uint32_t flags = 0;
    csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof flags);
    return flags;
}

static int is_traced(void) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) return -1;
    return (kp.kp_proc.p_flag & P_TRACED) != 0;
}

static void say_state(const char *when) {
    uint32_t f = cs_flags();
    say("state(%s): P_TRACED=%d cs_flags=0x%08x CS_DEBUGGED=%d CS_GET_TASK_ALLOW=%d CS_HARD=%d CS_KILL=%d "
        "CS_ENFORCEMENT=%d CS_RUNTIME=%d",
        when, is_traced(), f, !!(f & 0x10000000), !!(f & 0x4), !!(f & 0x100), !!(f & 0x200), !!(f & 0x1000),
        !!(f & 0x10000));
}

static void say_sysctl(const char *name) {
    uint64_t v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) {
        say("sysctl %s: error %d (%s)", name, errno, strerror(errno));
    } else {
        say("sysctl %s = %llu", name, len == 4 ? (unsigned long long)(uint32_t)v : (unsigned long long)v);
    }
}

static void say_env(void) {
    char build[64] = "?", machine[64] = "?";
    size_t len = sizeof build;
    sysctlbyname("kern.osversion", build, &len, NULL, 0);
    len = sizeof machine;
    sysctlbyname("hw.machine", machine, &len, NULL, 0);
    say("env: hw.machine=%s kern.osversion=%s vm_page_size=%lu pid=%d", machine, build, (unsigned long)vm_page_size,
        getpid());
}

static int wait_untraced(int seconds) {
    for (int i = 0; i < seconds * 10; i++) {
        if (is_traced() == 0) return 1;
        usleep(100000);
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// Memory helpers

static const char *prot_str(int p, char *b) {
    b[0] = (p & VM_PROT_READ) ? 'r' : '-';
    b[1] = (p & VM_PROT_WRITE) ? 'w' : '-';
    b[2] = (p & VM_PROT_EXECUTE) ? 'x' : '-';
    b[3] = 0;
    return b;
}

static void say_region(const char *label, const void *addr) {
    vm_address_t a = (vm_address_t)addr;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    char c[4], m[4];
    if (kr != KERN_SUCCESS) {
        say("%s: vm_region -> %d (%s)", label, kr, mach_error_string(kr));
    } else {
        say("%s: region %p size 0x%lx prot=%s max=%s", label, (void *)a, (unsigned long)size,
            prot_str(info.protection, c), prot_str(info.max_protection, m));
    }
}

static void put_ret_imm(void *dst, int imm) {
    uint32_t code[2] = {OP_MOVZ_W0(imm), OP_RET};
    memcpy(dst, code, sizeof code);
}

// mov w0, #0; add w0, w0, #1 (n times); ret. Returns n, which the code returns when called.
static int put_chain(void *dst, size_t bytes) {
    uint32_t *p = dst;
    size_t count = bytes / 4;
    p[0] = OP_MOVZ_W0(0);
    for (size_t i = 1; i < count - 1; i++) p[i] = OP_ADD1;
    p[count - 1] = OP_RET;
    return (int)(count - 2);
}

typedef int (*fn_t)(void);

static int call(const char *label, const void *addr, int expected) {
    say("%s: calling %p (expect %d)", label, addr, expected);
    int v = ((fn_t)addr)();
    say("%s: RESULT returned %d%s", label, v, v == expected ? " (as expected)" : " (UNEXPECTED)");
    return v == expected ? 0 : 1;
}

// ---------------------------------------------------------------------------------------------
// Debugger hook. lldb/spike_lldb.py sets a breakpoint on spike_hook, reads spike_req, does the
// work, writes result and status, and continues. Without a debugger status stays 0.

enum { HOOK_WRITE_RET = 1, HOOK_WRITE_CHAIN = 2, HOOK_ALLOC_RX = 3, HOOK_TOUCH = 4, HOOK_DETACH = 5 };

typedef struct {
    uint64_t cmd, addr, len, arg, result, status;
} spike_req_t;

__attribute__((used, visibility("default"))) volatile spike_req_t spike_req;

__attribute__((noinline, used, visibility("default"))) void spike_hook(void) { __asm__ volatile("" ::: "memory"); }

static int hook(uint64_t cmd, uint64_t addr, uint64_t len, uint64_t arg) {
    spike_req.cmd = cmd;
    spike_req.addr = addr;
    spike_req.len = len;
    spike_req.arg = arg;
    spike_req.result = 0;
    spike_req.status = 0;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    spike_hook();
    double ms = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    say("hook cmd=%llu addr=0x%llx len=%llu arg=%llu -> status=%llu result=0x%llx (round trip %.0f ms)", cmd, addr,
        len, arg, spike_req.status, spike_req.result, ms);
    return spike_req.status == 1;
}

static int need_debugger(void) {
    if (is_traced() == 1) return 1;
    say("RESULT skipped: needs a debugger (P_TRACED=0)");
    return 0;
}

static void detach_and_wait(void) {
    hook(HOOK_DETACH, 0, 0, 0);
    int ok = wait_untraced(20);
    say("after detach: untraced=%d", ok);
    say_state("after-detach");
}

// ---------------------------------------------------------------------------------------------
// Test 1: code the process writes itself

// 1a: mmap RW, write, mprotect RX, call.
static int t1a(void) {
    void *p = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) {
        say("RESULT mmap(RW) failed: errno=%d (%s)", errno, strerror(errno));
        return 1;
    }
    put_ret_imm(p, 42);
    int r = mprotect(p, PAGE, PROT_READ | PROT_EXEC);
    int e = errno;
    say("mprotect(RX) -> %d errno=%d (%s)", r, r ? e : 0, r ? strerror(e) : "-");
    say_region("after mprotect", p);
    sys_icache_invalidate(p, PAGE);
    return call("1a", p, 42);
}

// 1b: mmap RWX with MAP_JIT, toggle pthread_jit_write_protect_np if it exists.
static int t1b(void) {
    void (*wp)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    say("pthread_jit_write_protect_np: %s; pthread_jit_write_protect_supported_np() = %d", wp ? "present" : "absent",
        pthread_jit_write_protect_supported_np());
    void *p = mmap(NULL, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) {
        say("RESULT mmap(RWX, MAP_JIT) failed: errno=%d (%s)", errno, strerror(errno));
        return 1;
    }
    say_region("after mmap MAP_JIT", p);
    if (wp) wp(0);
    put_ret_imm(p, 42);
    if (wp) wp(1);
    sys_icache_invalidate(p, PAGE);
    return call("1b", p, 42);
}

// 1c: vm_protect(VM_PROT_COPY) on a page of the signed __TEXT, write, back to RX, call.
// This is what swapify does in the simulator for its 16-byte accessor jumps.
static int t1c(void) {
    vm_address_t a = (vm_address_t)spike_cave2;
    say_region("cave2 before", spike_cave2);
    kern_return_t kr = vm_protect(mach_task_self(), a, PAGE, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    say("vm_protect(RW|COPY) -> %d (%s)", kr, mach_error_string(kr));
    say_region("cave2 after RW|COPY", spike_cave2);
    if (kr != KERN_SUCCESS) {
        say("RESULT not called: page could not be made writable");
        return 1;
    }
    put_ret_imm(spike_cave2, 42);
    say("wrote 8 bytes into cave2");
    kr = vm_protect(mach_task_self(), a, PAGE, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    say("vm_protect(RX) -> %d (%s)", kr, mach_error_string(kr));
    say_region("cave2 after RX", spike_cave2);
    sys_icache_invalidate(spike_cave2, PAGE);
    return call("1c", spike_cave2, 42);
}

// 1d: mmap RWX without MAP_JIT.
static int t1d(void) {
    void *p = mmap(NULL, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) {
        say("RESULT mmap(RWX) failed: errno=%d (%s)", errno, strerror(errno));
        return 1;
    }
    say_region("after mmap RWX", p);
    put_ret_imm(p, 42);
    sys_icache_invalidate(p, PAGE);
    return call("1d", p, 42);
}

// Maps an RW alias of [rx, rx+size) with vm_remap and makes it writable. Returns 0 on failure.
static uint8_t *rw_alias(void *rx, size_t size) {
    vm_address_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)rx,
                                FALSE, &cur, &max, VM_INHERIT_NONE);
    char c[4], m[4];
    say("vm_remap(alias) -> %d (%s) alias=%p cur=%s max=%s", kr, mach_error_string(kr), (void *)rw,
        prot_str(cur, c), prot_str(max, m));
    if (kr != KERN_SUCCESS) return 0;
    kr = vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    say("vm_protect(alias, RW) -> %d (%s)", kr, mach_error_string(kr));
    say_region("alias", (void *)rw);
    say_region("rx view", rx);
    return kr == KERN_SUCCESS ? (uint8_t *)rw : 0;
}

// 1e: mmap RX, RW alias with vm_remap, write through the alias, call the RX view.
static int t1e(void) {
    void *rx = mmap(NULL, PAGE, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (rx == MAP_FAILED) {
        say("RESULT mmap(RX) failed: errno=%d (%s)", errno, strerror(errno));
        return 1;
    }
    say_region("after mmap RX", rx);
    uint8_t *rw = rw_alias(rx, PAGE);
    if (!rw) {
        say("RESULT not called: no writable alias");
        return 1;
    }
    put_ret_imm(rw, 42);
    sys_icache_invalidate(rx, PAGE);
    return call("1e", rx, 42);
}

// ---------------------------------------------------------------------------------------------
// Test 2: code the debugger writes

// 2cave: LLDB writes into the __TEXT cave with `memory write`: 8 bytes, then 32 KB across two pages.
// Then LLDB detaches and the app calls both again.
static int t2cave(void) {
    if (!need_debugger()) return 1;
    int rc = 0;
    if (hook(HOOK_WRITE_RET, (uint64_t)spike_cave, 8, 42)) {
        sys_icache_invalidate(spike_cave, 8);
        rc |= call("2a small write", spike_cave, 42);
    } else {
        say("RESULT 2a: debugger write failed");
        rc = 1;
    }
    uint8_t *big = (uint8_t *)spike_cave + PAGE + PAGE / 2; // 32 KB from the middle of page 1 into page 3
    if (hook(HOOK_WRITE_CHAIN, (uint64_t)big, 32768, 0)) {
        sys_icache_invalidate(big, 32768);
        rc |= call("2b 32 KB write", big, 32768 / 4 - 2);
    } else {
        say("RESULT 2b: debugger write failed");
        rc = 1;
    }
    detach_and_wait();
    rc |= call("2c small write after detach", spike_cave, 42);
    rc |= call("2c 32 KB write after detach", big, 32768 / 4 - 2);
    return rc;
}

// 2region: a region that the debugger prepares, then the app writes code through an RW alias.
// by_debugger: LLDB allocates the region (SBProcess.AllocateMemory, rx), otherwise the app maps it RX.
// prep: 0 = LLDB writes nothing (control), 1 = LLDB rewrites 1 byte per 16 KB page,
//       2 = LLDB writes zeros over the whole region in 1 MB writes.
static int t2region(int by_debugger, int prep, size_t size) {
    if (!need_debugger()) return 1;
    void *rx;
    if (by_debugger) {
        if (!hook(HOOK_ALLOC_RX, 0, size, (uint64_t)prep)) {
            say("RESULT debugger allocation failed");
            return 1;
        }
        rx = (void *)spike_req.result;
    } else {
        rx = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (rx == MAP_FAILED) {
            say("RESULT mmap(RX) failed: errno=%d (%s)", errno, strerror(errno));
            return 1;
        }
        if (prep && !hook(HOOK_TOUCH, (uint64_t)rx, size, (uint64_t)prep)) {
            say("RESULT debugger touch failed");
            return 1;
        }
    }
    say_region("region", rx);
    uint8_t *rw = rw_alias(rx, size);
    if (!rw) {
        say("RESULT not called: no writable alias");
        return 1;
    }
    int rc = 0;
    put_ret_imm(rw, 42);
    sys_icache_invalidate(rx, 8);
    rc |= call("A page 0, first write", rx, 42);
    put_ret_imm(rw, 43);
    sys_icache_invalidate(rx, 8);
    rc |= call("B page 0, rewrite", rx, 43);
    int n = put_chain(rw + 2 * PAGE + 4096, 8192);
    sys_icache_invalidate((uint8_t *)rx + 2 * PAGE + 4096, 8192);
    rc |= call("C page 2, 8 KB", (uint8_t *)rx + 2 * PAGE + 4096, n);
    detach_and_wait();
    put_ret_imm(rw + 3 * PAGE, 44);
    sys_icache_invalidate((uint8_t *)rx + 3 * PAGE, 8);
    rc |= call("D page 3, first write after detach", (uint8_t *)rx + 3 * PAGE, 44);
    put_ret_imm(rw, 45);
    sys_icache_invalidate(rx, 8);
    rc |= call("E page 0, rewrite after detach", rx, 45);
    if (size > 4 * PAGE) {
        uint8_t *last = (uint8_t *)rx + size - PAGE;
        put_ret_imm(rw + size - PAGE, 46);
        sys_icache_invalidate(last, 8);
        rc |= call("F last page, first write after detach", last, 46);
    }
    return rc;
}

// ---------------------------------------------------------------------------------------------
// Test 3: dlopen

// where: tmp, lib (framework in tmp/ or Library/), dylib (same-team dylib in tmp/), adhoc (ad hoc
// signed dylib in tmp/), otherteam (dylib signed by another team in tmp/), bundle (embedded framework).
// patch: after loading, LLDB overwrites the first 8 bytes of spike_plugin_value with `mov w0, #43; ret`.
static int t3(const char *where, int patch) {
    char path[1024];
    const char *home = getenv("HOME"), *tmp = getenv("TMPDIR");
    if (patch && !need_debugger()) return 1;
    if (!strcmp(where, "tmp")) {
        snprintf(path, sizeof path, "%sSpikePlugin.framework/SpikePlugin", tmp);
    } else if (!strcmp(where, "lib")) {
        snprintf(path, sizeof path, "%s/Library/SpikePlugin.framework/SpikePlugin", home);
    } else if (!strcmp(where, "dylib")) {
        snprintf(path, sizeof path, "%slibspikeplugin.dylib", tmp);
    } else if (!strcmp(where, "adhoc")) {
        snprintf(path, sizeof path, "%slibspikeplugin-adhoc.dylib", tmp);
    } else if (!strcmp(where, "otherteam")) {
        snprintf(path, sizeof path, "%slibspikeplugin-otherteam.dylib", tmp);
    } else {
        char exe[1024];
        snprintf(exe, sizeof exe, "%s", _dyld_get_image_name(0));
        char *slash = strrchr(exe, '/');
        if (slash) *slash = 0;
        snprintf(path, sizeof path, "%s/Frameworks/SpikePlugin.framework/SpikePlugin", exe);
    }
    struct stat st;
    int exists = stat(path, &st) == 0;
    say("path %s exists=%d size=%lld", path, exists, exists ? (long long)st.st_size : -1LL);
    void *h = dlopen(path, RTLD_NOW);
    if (!h) {
        say("RESULT dlopen failed: %s", dlerror());
        return 1;
    }
    int (*f)(void) = (int (*)(void))dlsym(h, "spike_plugin_value");
    if (!f) {
        say("RESULT dlsym failed: %s", dlerror());
        return 1;
    }
    int v = f();
    say("RESULT dlopen ok, spike_plugin_value() = %d", v);
    if (!patch) return v == 42 ? 0 : 1;
    say_region("spike_plugin_value page", (void *)f);
    if (!hook(HOOK_WRITE_RET, (uint64_t)f, 8, 43)) {
        say("RESULT debugger write failed");
        return 1;
    }
    sys_icache_invalidate((void *)f, 8);
    int rc = call("patched by LLDB", (void *)f, 43);
    detach_and_wait();
    rc |= call("patched by LLDB, after detach", (void *)f, 43);
    return rc;
}

// ---------------------------------------------------------------------------------------------
// Test 4: transport. A TCP listener on [::]:7777 (dual stack) and a 300 KB file in tmp/.

static int read_line(int fd, char *buf, size_t cap) {
    size_t n = 0;
    while (n + 1 < cap) {
        char ch;
        ssize_t r = recv(fd, &ch, 1, 0);
        if (r <= 0) return 0;
        if (ch == '\n') break;
        buf[n++] = ch;
    }
    buf[n] = 0;
    return 1;
}

static int send_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = send(fd, b, n, 0);
        if (w <= 0) return 0;
        b += w;
        n -= (size_t)w;
    }
    return 1;
}

static uint8_t g_blob[1 << 20];

// Connects to a numeric host and port. Returns the socket, or -1 with errno set; *ms is the connect time.
static int dial_to(const char *host, const char *port, double *ms) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST;
    int err = getaddrinfo(host, port, &hints, &res);
    if (err || !res) {
        say("getaddrinfo(%s) failed: %s", host, gai_strerror(err));
        errno = EINVAL;
        return -1;
    }
    int s = socket(res->ai_family, SOCK_STREAM, 0);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int r = connect(s, res->ai_addr, res->ai_addrlen);
    int e = errno;
    *ms = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    freeaddrinfo(res);
    if (r != 0) {
        close(s);
        errno = e;
        return -1;
    }
    return s;
}

// Protocol: PING -> PONG; PUT <n> + n bytes -> OK <n>; GET <n> -> n bytes;
// DIAL <host> <port> -> the app connects to the Mac and serves this protocol there too.
static void *serve_client(void *arg) {
    int fd = (int)(intptr_t)arg;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    char line[128];
    static uint8_t sink[65536];
    while (read_line(fd, line, sizeof line)) {
        if (!strcmp(line, "PING")) {
            if (!send_all(fd, "PONG\n", 5)) break;
        } else if (!strncmp(line, "PUT ", 4)) {
            size_t left = strtoul(line + 4, NULL, 10), total = left;
            while (left) {
                ssize_t r = recv(fd, sink, left < sizeof sink ? left : sizeof sink, 0);
                if (r <= 0) goto done;
                left -= (size_t)r;
            }
            char ok[64];
            int k = snprintf(ok, sizeof ok, "OK %zu\n", total);
            if (!send_all(fd, ok, (size_t)k)) break;
        } else if (!strncmp(line, "GET ", 4)) {
            size_t n = strtoul(line + 4, NULL, 10);
            if (n > sizeof g_blob) n = sizeof g_blob;
            if (!send_all(fd, g_blob, n)) break;
        } else if (!strncmp(line, "DIAL ", 5)) {
            char host[128] = "", port[16] = "", msg[160];
            sscanf(line + 5, "%127s %15s", host, port);
            double ms = 0;
            int s = dial_to(host, port, &ms);
            int k;
            if (s < 0) {
                int e = errno;
                say("DIAL %s port %s failed after %.0f ms: errno=%d (%s)", host, port, ms, e, strerror(e));
                k = snprintf(msg, sizeof msg, "FAIL errno=%d (%s) after %.0f ms\n", e, strerror(e), ms);
            } else {
                say("DIAL %s port %s connected in %.0f ms", host, port, ms);
                k = snprintf(msg, sizeof msg, "DIALED %.0f ms\n", ms);
                pthread_t t;
                pthread_create(&t, NULL, serve_client, (void *)(intptr_t)s);
                pthread_detach(t);
            }
            if (!send_all(fd, msg, (size_t)k)) break;
        } else {
            break;
        }
    }
done:
    close(fd);
    return NULL;
}

// The other direction: the app connects to a listener on the Mac (SPIKE_DIAL="host,port", passed as
// DEVICECTL_CHILD_SPIKE_DIAL) and serves the same protocol on that connection.
static int tdial(void) {
    const char *spec = getenv("SPIKE_DIAL");
    char host[128] = "", *port;
    snprintf(host, sizeof host, "%s", spec ? spec : "");
    port = strchr(host, ',');
    if (!port) {
        say("RESULT SPIKE_DIAL must be host,port");
        return 1;
    }
    *port++ = 0;
    double ms = 0;
    int s = dial_to(host, port, &ms);
    if (s < 0) {
        int e = errno;
        say("RESULT connect to %s port %s failed after %.0f ms: errno=%d (%s)", host, port, ms, e, strerror(e));
        return 1;
    }
    say("connected to %s port %s in %.0f ms; serving", host, port, ms);
    serve_client((void *)(intptr_t)s);
    say("RESULT connection closed by the Mac");
    return 0;
}

// Prints a line every 5 s. A suspended app prints nothing.
static void *heartbeat(void *arg) {
    (void)arg;
    for (int i = 1;; i++) {
        sleep(5);
        say("heartbeat %d s", i * 5);
    }
    return NULL;
}

static int tserve(void) {
    pthread_t hb;
    pthread_create(&hb, NULL, heartbeat, NULL);
    pthread_detach(hb);
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *i = list; i; i = i->ifa_next) {
            if (!i->ifa_addr) continue;
            char s[INET6_ADDRSTRLEN] = "";
            if (i->ifa_addr->sa_family == AF_INET) {
                inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, s, sizeof s);
            } else if (i->ifa_addr->sa_family == AF_INET6) {
                inet_ntop(AF_INET6, &((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, s, sizeof s);
            } else {
                continue;
            }
            say("ifaddr %s %s", i->ifa_name, s);
        }
        freeifaddrs(list);
    }
    arc4random_buf(g_blob, sizeof g_blob);
    char path[1024];
    snprintf(path, sizeof path, "%sout300k.bin", getenv("TMPDIR"));
    FILE *f = fopen(path, "wb");
    if (f) {
        fwrite(g_blob, 1, 300 * 1024, f);
        fclose(f);
    }
    say("wrote %s", path);

    int s = socket(AF_INET6, SOCK_STREAM, 0);
    int no = 0, yes = 1;
    setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof no);
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in6 a;
    memset(&a, 0, sizeof a);
    a.sin6_len = sizeof a;
    a.sin6_family = AF_INET6;
    a.sin6_port = htons(7777);
    a.sin6_addr = in6addr_any;
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 8) != 0) {
        say("RESULT listen failed: errno=%d (%s)", errno, strerror(errno));
        return 1;
    }
    say("listening on [::]:7777");
    for (;;) {
        struct sockaddr_in6 peer;
        socklen_t plen = sizeof peer;
        int c = accept(s, (struct sockaddr *)&peer, &plen);
        if (c < 0) continue;
        char ps[INET6_ADDRSTRLEN] = "";
        inet_ntop(AF_INET6, &peer.sin6_addr, ps, sizeof ps);
        say("accepted connection from %s", ps);
        pthread_t t;
        pthread_create(&t, NULL, serve_client, (void *)(intptr_t)c);
        pthread_detach(t);
    }
}

// ---------------------------------------------------------------------------------------------

int spike_run(const char *test) {
    g_test = test;
    g_log = os_log_create("dev.swapify.spike", "spike");
    install_signal_handlers();
    signal(SIGPIPE, SIG_IGN); // the Mac closing a connection must not kill the app
    say_env();
    say_state("start");
    say_sysctl("kern.sptm.boot_timestamps.txm_bootstrap");
    say_sysctl("vm.cs_defer_to_csm");
    // `<test>+wait` waits up to 90 s for a debugger that attaches to the running process.
    char name[64];
    snprintf(name, sizeof name, "%s", test);
    char *plus = strchr(name, '+');
    if (plus && !strcmp(plus, "+wait")) {
        *plus = 0;
        say("waiting for a debugger to attach");
        for (int i = 0; i < 900 && is_traced() != 1; i++) usleep(100000);
        say_state("after-wait");
    }
    int rc;
    if (!strcmp(name, "1a")) rc = t1a();
    else if (!strcmp(name, "1b")) rc = t1b();
    else if (!strcmp(name, "1c")) rc = t1c();
    else if (!strcmp(name, "1d")) rc = t1d();
    else if (!strcmp(name, "1e")) rc = t1e();
    else if (!strcmp(name, "2cave")) rc = t2cave();
    else if (!strcmp(name, "2region-dbg")) rc = t2region(1, 1, 4 * PAGE);
    else if (!strcmp(name, "2region-app")) rc = t2region(0, 1, 4 * PAGE);
    else if (!strcmp(name, "2region-notouch")) rc = t2region(0, 0, 4 * PAGE);
    else if (!strcmp(name, "2region-big")) rc = t2region(1, 2, 16u << 20);
    else if (!strcmp(name, "3tmp")) rc = t3("tmp", 0);
    else if (!strcmp(name, "3lib")) rc = t3("lib", 0);
    else if (!strcmp(name, "3dylib")) rc = t3("dylib", 0);
    else if (!strcmp(name, "3adhoc")) rc = t3("adhoc", 0);
    else if (!strcmp(name, "3otherteam")) rc = t3("otherteam", 0);
    else if (!strcmp(name, "3bundle")) rc = t3("bundle", 0);
    else if (!strcmp(name, "3patch")) rc = t3("tmp", 1);
    else if (!strcmp(name, "serve")) rc = tserve();
    else if (!strcmp(name, "dial")) rc = tdial();
    else {
        say("unknown test");
        rc = 2;
    }
    say("END rc=%d", rc);
    return rc;
}
