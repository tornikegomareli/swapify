// HotAgent: loads patch dylibs into a running app built with
// `-enable-implicit-dynamic` and makes them take effect.
//
// Functions, old -> new: every dynamic Swift function starts by checking its
// chain root (`$s...TX`). The agent copies the patch's root into the app's root,
// so old code forwards to the new body.
//
// Types and statics, new -> old: the patch defines its own copy of every type
// and static in the edited file. The agent overwrites the start of each new
// metadata accessor (`$s...Ma`) and addressor (`$s...vau`) with a jump to the
// app's original, so new code keeps using the original types and storage.
//
// Protocol (one line per command on 127.0.0.1:$HOTRELOAD_PORT, default 8899):
//   load <absolute dylib path>   -> {"ok":true,"generation":N,...}
//   refresh                      -> re-renders every SwiftUI hosting view
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <sys/socket.h>
#include <time.h>

#define LOG(...) fprintf(stderr, "[HotAgent] " __VA_ARGS__)

typedef struct {
    const char *name;
    uintptr_t addr;
} Sym;

typedef struct {
    Sym *syms;
    size_t count;
} SymTable;  // sorted by name

typedef struct {
    SymTable roots;      // $s...TX dynamic replacement chain roots
    SymTable accessors;  // $s...Ma type metadata accessors, $s...vau addressors
} Image;

static Image targets[512];  // app images first, then loaded patches
static int targetCount, appImageCount, generation;

static int hasSuffix(const char *s, const char *suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n > m && strcmp(s + n - m, suffix) == 0;
}

static int compareNames(const void *a, const void *b) {
    return strcmp(((const Sym *)a)->name, ((const Sym *)b)->name);
}

static int compareAddrs(const void *a, const void *b) {
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return x < y ? -1 : x > y;
}

static Sym *lookup(SymTable *table, const char *name) {
    Sym key = {name, 0};
    return bsearch(&key, table->syms, table->count, sizeof(Sym), compareNames);
}

// Reads the image's symbol table, local symbols included. If `addrs` is set,
// it also returns every defined symbol address, sorted, to measure sizes.
static Image readImage(uint32_t index, uintptr_t **addrs, size_t *addrCount) {
    Image image = {0};
    const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(index);
    intptr_t slide = _dyld_get_image_vmaddr_slide(index);
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 &&
            strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)lc;
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    if (!symtab || !linkedit) return image;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);

    image.roots.syms = malloc(sizeof(Sym) * (symtab->nsyms + 1));
    image.accessors.syms = malloc(sizeof(Sym) * (symtab->nsyms + 1));
    if (addrs) *addrs = malloc(sizeof(uintptr_t) * (symtab->nsyms + 1));
    if (addrCount) *addrCount = 0;
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        const struct nlist_64 *s = &syms[i];
        if ((s->n_type & N_STAB) || (s->n_type & N_TYPE) != N_SECT) continue;
        const char *name = strings + s->n_un.n_strx;
        uintptr_t addr = s->n_value + slide;
        if (addrs) (*addrs)[(*addrCount)++] = addr;
        if (strncmp(name, "_$s", 3) != 0) continue;
        if (hasSuffix(name, "TX"))
            image.roots.syms[image.roots.count++] = (Sym){name, addr};
        else if (hasSuffix(name, "Ma") || hasSuffix(name, "vau"))
            image.accessors.syms[image.accessors.count++] = (Sym){name, addr};
    }
    qsort(image.roots.syms, image.roots.count, sizeof(Sym), compareNames);
    qsort(image.accessors.syms, image.accessors.count, sizeof(Sym), compareNames);
    if (addrs) qsort(*addrs, *addrCount, sizeof(uintptr_t), compareAddrs);
    return image;
}

static void addTarget(uint32_t index) {
    targets[targetCount] = readImage(index, NULL, NULL);
    LOG("image %s: %zu roots, %zu accessors\n", _dyld_get_image_name(index),
        targets[targetCount].roots.count, targets[targetCount].accessors.count);
    targetCount++;
}

// App images: every image in the main executable's directory.
static void collectAppImages(void) {
    char dir[PATH_MAX] = "";
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i)->filetype == MH_EXECUTE)
            strlcpy(dir, _dyld_get_image_name(i), sizeof dir);
    char *slash = strrchr(dir, '/');
    if (slash) slash[1] = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strncmp(_dyld_get_image_name(i), dir, strlen(dir)) == 0) addTarget(i);
    appImageCount = targetCount;
}

static int findImage(const char *path, uint32_t first) {
    char real[PATH_MAX], other[PATH_MAX];
    if (!realpath(path, real)) strlcpy(real, path, sizeof real);
    for (uint32_t i = first; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!realpath(name, other)) strlcpy(other, name, sizeof other);
        if (strcmp(real, other) == 0) return (int)i;
    }
    return -1;
}

// Overwrites 16 bytes at `at` with `ldr x16, #8; br x16; .quad to`.
static int writeJump(uintptr_t at, uintptr_t to) {
    uint32_t code[4] = {0x58000050, 0xd61f0200, 0, 0};
    memcpy(&code[2], &to, sizeof to);
    vm_address_t page = at & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t length = at + sizeof code - page;
    if (vm_protect(mach_task_self(), page, length, FALSE,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return 0;
    memcpy((void *)at, code, sizeof code);
    vm_protect(mach_task_self(), page, length, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void *)at, sizeof code);
    return 1;
}

static size_t symbolSize(uintptr_t addr, uintptr_t *addrs, size_t count) {
    for (size_t i = 0; i < count; i++)
        if (addrs[i] > addr) return addrs[i] - addr;
    return 0;
}

static double nowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void loadPatch(const char *path, char *reply, size_t replySize) {
    double start = nowMs();
    uint32_t imagesBefore = _dyld_image_count();
    if (!dlopen(path, RTLD_NOW)) {
        snprintf(reply, replySize, "{\"ok\":false,\"error\":\"%s\"}", dlerror());
        return;
    }
    double loaded = nowMs();
    int index = findImage(path, imagesBefore);
    if (index < 0) {
        snprintf(reply, replySize, "{\"ok\":false,\"error\":\"image not found after dlopen\"}");
        return;
    }
    uintptr_t *addrs;
    size_t addrCount;
    Image fresh = readImage((uint32_t)index, &addrs, &addrCount);

    // New -> old first, before any new code can run.
    int shared = 0, tooSmall = 0;
    for (size_t i = 0; i < fresh.accessors.count; i++) {
        Sym *newSym = &fresh.accessors.syms[i];
        for (int t = 0; t < appImageCount; t++) {
            Sym *old = lookup(&targets[t].accessors, newSym->name);
            if (!old) continue;
            if (symbolSize(newSym->addr, addrs, addrCount) < 16) tooSmall++;
            else if (writeJump(newSym->addr, old->addr)) shared++;
            break;
        }
    }

    // Old -> new: app images and earlier patches forward to this patch.
    int patched = 0, added = 0;
    for (size_t i = 0; i < fresh.roots.count; i++) {
        Sym *newRoot = &fresh.roots.syms[i];
        int found = 0;
        for (int t = 0; t < targetCount; t++) {
            Sym *old = lookup(&targets[t].roots, newRoot->name);
            if (!old) continue;
            ((void **)old->addr)[0] = ((void **)newRoot->addr)[0];
            found = 1;
            patched++;
        }
        if (!found) added++;
    }
    free(addrs);
    free(fresh.accessors.syms);
    fresh.accessors = (SymTable){0};
    targets[targetCount++] = fresh;
    generation++;
    double done = nowMs();

    dispatch_async(dispatch_get_main_queue(), ^{
        CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                                             CFSTR("INJECTION_BUNDLE_NOTIFICATION"),
                                             NULL, NULL, true);
    });
    snprintf(reply, replySize,
             "{\"ok\":true,\"generation\":%d,\"patched\":%d,\"new\":%d,\"shared\":%d,"
             "\"tooSmall\":%d,\"dlopenMs\":%.2f,\"patchMs\":%.2f}",
             generation, patched, added, shared, tooSmall, loaded - start, done - loaded);
}

// SwiftUI refresh. It repeats SwiftUI.AppPreviewHost.invalidateEverything()
// for every _UIHostingView, but skips GraphHost.incrementPhase(), which resets
// all @State. All symbols are exported from SwiftUI and SwiftUICore.
#define SWIFTCALL __attribute__((swiftcall))
#define SWIFTSELF __attribute__((swift_context))  // lowers to LLVM swiftself (x20)
typedef void *(*SelfGetter)(void *self SWIFTSELF) SWIFTCALL;
typedef void (*SelfMethod)(void *self SWIFTSELF) SWIFTCALL;
typedef uint32_t (*EmptyTransaction)(void *transaction, void *self SWIFTSELF) SWIFTCALL;

static struct {
    SelfGetter hostingViewGraph;  // _UIHostingView.viewGraph.getter, returns +1
    SelfGetter graph;             // GraphHost.graph.getter -> AGGraphRef
    EmptyTransaction emptyTransaction;
    SelfMethod flushTransactions;
    void (*invalidateAllValues)(void *graph);
    void (*invalidateLazyContainers)(void);  // DebugReplaceableView.invalidateEverything()
    void (*release)(void *);
} SwiftUIAPI;

static int resolveSwiftUI(void) {
    if (SwiftUIAPI.hostingViewGraph) return 1;
    SwiftUIAPI.hostingViewGraph = dlsym(RTLD_DEFAULT, "$s7SwiftUI14_UIHostingViewC9viewGraphAA0dF0Cvg");
    SwiftUIAPI.graph = dlsym(RTLD_DEFAULT, "$s7SwiftUI9GraphHostC5graphSo10AGGraphRefavg");
    SwiftUIAPI.emptyTransaction = dlsym(RTLD_DEFAULT, "$s7SwiftUI9GraphHostC16emptyTransactionys6UInt32VAA0F0VF");
    SwiftUIAPI.flushTransactions = dlsym(RTLD_DEFAULT, "$s7SwiftUI9GraphHostC17flushTransactionsyyF");
    SwiftUIAPI.invalidateAllValues = dlsym(RTLD_DEFAULT, "AGGraphInvalidateAllValues");
    SwiftUIAPI.invalidateLazyContainers = dlsym(RTLD_DEFAULT, "$s7SwiftUI20DebugReplaceableViewV20invalidateEverythingyyFZ");
    SwiftUIAPI.release = dlsym(RTLD_DEFAULT, "swift_release");
    int ok = SwiftUIAPI.hostingViewGraph && SwiftUIAPI.graph && SwiftUIAPI.emptyTransaction &&
             SwiftUIAPI.flushTransactions && SwiftUIAPI.invalidateAllValues &&
             SwiftUIAPI.invalidateLazyContainers && SwiftUIAPI.release;
    if (!ok) {
        LOG("SwiftUI refresh symbols missing\n");
        SwiftUIAPI.hostingViewGraph = NULL;
    }
    return ok;
}

static void collectHostingViews(UIView *view, NSMutableArray *out) {
    for (Class c = object_getClass(view); c; c = class_getSuperclass(c))
        if (strstr(class_getName(c), "_UIHostingView")) {
            [out addObject:view];
            break;
        }
    for (UIView *sub in view.subviews) collectHostingViews(sub, out);
}

// Main thread only. Returns the number of hosting views, or -1.
static int refreshSwiftUI(void) {
    if (!resolveSwiftUI()) return -1;
    NSMutableArray *hosts = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *window in ((UIWindowScene *)scene).windows)
                collectHostingViews(window, hosts);

    SwiftUIAPI.invalidateLazyContainers();
    for (UIView *view in hosts) {
        void *viewGraph = SwiftUIAPI.hostingViewGraph((__bridge void *)view);
        SwiftUIAPI.invalidateAllValues(SwiftUIAPI.graph(viewGraph));
        SwiftUIAPI.emptyTransaction(NULL, viewGraph);
        SwiftUIAPI.flushTransactions(viewGraph);
        SwiftUIAPI.release(viewGraph);
    }
    return (int)hosts.count;
}

static void serve(int client) {
    FILE *io = fdopen(client, "r+");
    char line[PATH_MAX + 16], reply[PATH_MAX + 256];
    while (fgets(line, sizeof line, io)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strncmp(line, "load ", 5) == 0) {
            loadPatch(line + 5, reply, sizeof reply);
        } else if (strcmp(line, "refresh") == 0) {
            __block double ms = 0;
            __block int hosts = 0;
            dispatch_sync(dispatch_get_main_queue(), ^{
                double start = nowMs();
                hosts = refreshSwiftUI();
                ms = nowMs() - start;
            });
            snprintf(reply, sizeof reply, "{\"ok\":%s,\"hosts\":%d,\"refreshMs\":%.2f}",
                     hosts >= 0 ? "true" : "false", hosts, ms);
        } else {
            snprintf(reply, sizeof reply, "{\"ok\":false,\"error\":\"unknown command\"}");
        }
        LOG("%s -> %s\n", line, reply);
        fprintf(io, "%s\n", reply);
        fflush(io);
    }
    fclose(io);
}

static void *listenLoop(void *unused) {
    const char *env = getenv("HOTRELOAD_PORT");
    int port = env ? atoi(env) : 8899;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (void *)&addr, sizeof addr) || listen(fd, 4)) {
        LOG("cannot listen on %d\n", port);
        return NULL;
    }
    LOG("listening on 127.0.0.1:%d\n", port);
    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client >= 0) serve(client);
    }
}

__attribute__((constructor)) static void start(void) {
    collectAppImages();
    pthread_t thread;
    pthread_create(&thread, NULL, listenLoop, NULL);
    pthread_detach(thread);
}
