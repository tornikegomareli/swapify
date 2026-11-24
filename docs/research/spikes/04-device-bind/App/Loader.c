// Loads a patch with dlopen and makes it live with data writes only: each chain root ($s…TX) of the
// patch is copied into the root of the same name in the app and in earlier patches. No code page is
// written. Also reports what dyld bound the patch's GOT to, and a __DATA_CONST write probe.
#include "Loader.h"

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

void spike_say(const char *text) {
    char line[2048];
    int n = snprintf(line, sizeof line, "SPIKE %s\n", text);
    write(STDOUT_FILENO, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
}

static void sayf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sayf(const char *fmt, ...) {
    char text[1800];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    spike_say(text);
}

static double now_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static void on_signal(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    char line[160];
    int n = snprintf(line, sizeof line, "SPIKE CRASH signal=%d si_code=%d si_addr=%p\n", sig, si->si_code, si->si_addr);
    write(STDOUT_FILENO, line, (size_t)n);
    _exit(100 + sig);
}

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

void spike_say_state(void) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    sysctl(mib, 4, &kp, &len, NULL, 0);
    uint32_t flags = 0;
    csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof flags);
    sayf("state: P_TRACED=%d CS_DEBUGGED=%d cs_flags=0x%08x", !!(kp.kp_proc.p_flag & P_TRACED),
         !!(flags & 0x10000000), flags);
}

void spike_install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO;
    int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT};
    for (size_t i = 0; i < sizeof signals / sizeof *signals; i++) sigaction(signals[i], &sa, NULL);
}

// ---------------------------------------------------------------------------------------------
// Mach-O of a loaded image

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    const struct nlist_64 *symbols;
    uint32_t symbolCount;
    const char *strings;
    const uint32_t *indirect;
} image_t;

static image_t image_at(uint32_t index) {
    image_t im = {(const void *)_dyld_get_image_header(index), _dyld_get_image_vmaddr_slide(index), 0, 0, 0, 0};
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *lc = (const void *)(im.header + 1);
    for (uint32_t i = 0; i < im.header->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        if (lc->cmd == LC_DYSYMTAB) dysymtab = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT))
            linkedit = (const void *)lc;
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    if (!symtab || !linkedit) return im;
    uintptr_t base = (uintptr_t)im.slide + linkedit->vmaddr - linkedit->fileoff;
    im.symbols = (const void *)(base + symtab->symoff);
    im.symbolCount = symtab->nsyms;
    im.strings = (const char *)(base + symtab->stroff);
    if (dysymtab) im.indirect = (const void *)(base + dysymtab->indirectsymoff);
    return im;
}

// Address of a defined symbol (local ones included), or 0.
static uintptr_t defined(const image_t *im, const char *name) {
    for (uint32_t i = 0; i < im->symbolCount; i++) {
        const struct nlist_64 *s = &im->symbols[i];
        if ((s->n_type & N_STAB) || (s->n_type & N_TYPE) != N_SECT) continue;
        if (!strcmp(im->strings + s->n_un.n_strx, name)) return s->n_value + (uintptr_t)im->slide;
    }
    return 0;
}

static int main_index(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i)->filetype == MH_EXECUTE) return (int)i;
    return -1;
}

static int index_of(const char *path) {
    char real[PATH_MAX], other[PATH_MAX];
    if (!realpath(path, real)) snprintf(real, sizeof real, "%s", path);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!realpath(_dyld_get_image_name(i), other)) snprintf(other, sizeof other, "%s", _dyld_get_image_name(i));
        if (!strcmp(real, other)) return (int)i;
    }
    return -1;
}

// For every GOT slot of the patch that names a Swift symbol: the bound value, against the address
// the app exports for that name (dlsym on the main executable) or defines locally.
static void report_got(const image_t *patch, const image_t *app) {
    int swiftSlots = 0, toApp = 0, other = 0;
    const struct load_command *lc = (const void *)(patch->header + 1);
    for (uint32_t c = 0; c < patch->header->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sect = (const void *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;  // __got, and __la_symbol_ptr (bound now: RTLD_NOW)
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            const uintptr_t *slots = (const void *)(sect->addr + (uintptr_t)patch->slide);
            for (uint64_t i = 0; i < sect->size / 8; i++) {
                uint32_t symbol = patch->indirect[sect->reserved1 + i];
                if (symbol & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                const char *name = patch->strings + patch->symbols[symbol].n_un.n_strx;
                if (strncmp(name, "_$s", 3)) continue;
                swiftSlots++;
                void *exported = dlsym(RTLD_MAIN_ONLY, name + 1);
                uintptr_t expected = exported ? (uintptr_t)exported : defined(app, name);
                if (!expected) {
                    other++;  // not an app symbol: the Swift runtime or the SDK
                    continue;
                }
                if (slots[i] == expected) toApp++;
                else sayf("slot %s -> %p, app has %p (%s)", name, (void *)slots[i], (void *)expected,
                          exported ? "exported" : "local only");
            }
        }
    }
    sayf("pointer slots of the patch: %d name Swift symbols, %d hold the app's own address, %d other images",
         swiftSlots, toApp, other);
}

#define MAX_PATCHES 16
static int patches[MAX_PATCHES], patchCount;

// Copies every patch root into the root of the same name in `target`. Returns the number copied.
static int copy_roots(const image_t *patch, const image_t *target) {
    int copied = 0;
    for (uint32_t i = 0; i < patch->symbolCount; i++) {
        const struct nlist_64 *s = &patch->symbols[i];
        if ((s->n_type & N_STAB) || (s->n_type & N_TYPE) != N_SECT) continue;
        const char *name = patch->strings + s->n_un.n_strx;
        size_t n = strlen(name);
        if (strncmp(name, "_$s", 3) || n < 3 || strcmp(name + n - 2, "TX")) continue;
        uintptr_t old = defined(target, name);
        if (!old) continue;
        ((void **)old)[0] = ((void **)(s->n_value + (uintptr_t)patch->slide))[0];  // a data write
        copied++;
    }
    return copied;
}

int spike_load_patch(const char *path) {
    double t0 = now_ms();
    void *handle = dlopen(path, RTLD_NOW);
    double t1 = now_ms();
    if (!handle) {
        sayf("dlopen %s failed: %s", path, dlerror());
        return 1;
    }
    int index = index_of(path);
    if (index < 0 || patchCount == MAX_PATCHES) {
        sayf("patch image not found after dlopen");
        return 1;
    }
    image_t patch = image_at((uint32_t)index), app = image_at((uint32_t)main_index());
    report_got(&patch, &app);
    double t2 = now_ms();
    int intoApp = copy_roots(&patch, &app), intoPatches = 0;
    for (int p = 0; p < patchCount; p++) {
        image_t earlier = image_at((uint32_t)patches[p]);
        intoPatches += copy_roots(&patch, &earlier);
    }
    double t3 = now_ms();
    patches[patchCount++] = index;
    sayf("loaded %s: dlopen %.1f ms, roots copied into the app %d and into earlier patches %d in %.2f ms",
         strrchr(path, '/') + 1, t1 - t0, intoApp, intoPatches, t3 - t2);
    return 0;
}

// Can a __DATA_CONST page be made writable? Writes back the value it reads.
void spike_dataconst_probe(void) {
    const struct mach_header_64 *h = (const void *)_dyld_get_image_header((uint32_t)main_index());
    intptr_t slide = _dyld_get_image_vmaddr_slide((uint32_t)main_index());
    const struct load_command *lc = (const void *)(h + 1);
    for (uint32_t c = 0; c < h->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strcmp(seg->segname, "__DATA_CONST")) continue;
        volatile uint64_t *word = (volatile uint64_t *)(seg->vmaddr + (uintptr_t)slide);
        void *page = (void *)((uintptr_t)word & ~(uintptr_t)(vm_page_size - 1));
        int r = mprotect(page, vm_page_size, PROT_READ | PROT_WRITE);
        sayf("dataconst mprotect(__DATA_CONST page, RW) -> %d errno=%d (%s)", r, r ? errno : 0,
             r ? strerror(errno) : "-");
        if (r == 0) {
            uint64_t value = *word;
            *word = value;
            sayf("dataconst wrote a word into __DATA_CONST after mprotect: ok");
            mprotect(page, vm_page_size, PROT_READ);
        }
        kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, FALSE,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        sayf("dataconst vm_protect(__DATA_CONST page, RW|COPY) -> %d (%s)", kr, mach_error_string(kr));
        if (kr == KERN_SUCCESS) {
            uint64_t value = *word;
            *word = value;
            sayf("dataconst wrote a word into __DATA_CONST after vm_protect: ok");
        }
        return;
    }
    sayf("dataconst: no __DATA_CONST segment");
}
