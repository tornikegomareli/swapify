// Spike: chain-root patching.
// Loads a patch dylib and points every old Swift dynamic-replacement chain
// root (`$s...TX`) at the function with the same name in the patch.
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define LOG(...) fprintf(stderr, "[HotAgent] " __VA_ARGS__)

typedef struct {
    const char *name;
    void **addr;
} Root;

typedef struct {
    Root *roots;
    size_t count;
} RootTable;

static char *targetPaths[256];   // app images and earlier patches
static RootTable targetRoots[256];
static int targetCount;
static int generation;

static int endsWithTX(const char *s) {
    size_t n = strlen(s);
    return n > 4 && strncmp(s, "_$s", 3) == 0 && s[n - 2] == 'T' && s[n - 1] == 'X';
}

static int compareRoots(const void *a, const void *b) {
    return strcmp(((const Root *)a)->name, ((const Root *)b)->name);
}

// Collects every defined `_$s...TX` symbol of an image, local symbols included.
static RootTable collectRoots(const struct mach_header_64 *mh, intptr_t slide) {
    RootTable table = {0};
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
    if (!symtab || !linkedit) return table;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);

    table.roots = malloc(sizeof(Root) * (symtab->nsyms + 1));
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        const struct nlist_64 *s = &syms[i];
        if ((s->n_type & N_STAB) || (s->n_type & N_TYPE) != N_SECT) continue;
        const char *name = strings + s->n_un.n_strx;
        if (!endsWithTX(name)) continue;
        table.roots[table.count++] = (Root){name, (void **)(s->n_value + slide)};
    }
    qsort(table.roots, table.count, sizeof(Root), compareRoots);
    return table;
}

static int findImage(const char *path) {
    char real[PATH_MAX];
    if (!realpath(path, real)) strlcpy(real, path, sizeof real);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char other[PATH_MAX];
        if (!realpath(name, other)) strlcpy(other, name, sizeof other);
        if (strcmp(real, other) == 0) return (int)i;
    }
    return -1;
}

static void addTarget(uint32_t index) {
    targetPaths[targetCount] = strdup(_dyld_get_image_name(index));
    targetRoots[targetCount] = collectRoots(
        (const struct mach_header_64 *)_dyld_get_image_header(index),
        _dyld_get_image_vmaddr_slide(index));
    LOG("target %s: %zu roots\n", targetPaths[targetCount], targetRoots[targetCount].count);
    targetCount++;
}

// App images: every image inside the main executable's directory.
static void collectAppImages(void) {
    char bundle[PATH_MAX] = "";
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i)->filetype == MH_EXECUTE)
            strlcpy(bundle, _dyld_get_image_name(i), sizeof bundle);
    char *slash = strrchr(bundle, '/');
    if (slash) slash[1] = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strncmp(_dyld_get_image_name(i), bundle, strlen(bundle)) == 0) addTarget(i);
}

static double nowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void loadPatch(const char *path, char *reply, size_t replySize) {
    double start = nowMs();
    if (!dlopen(path, RTLD_NOW)) {
        snprintf(reply, replySize, "{\"ok\":false,\"error\":\"%s\"}", dlerror());
        return;
    }
    double loaded = nowMs();
    int index = findImage(path);
    if (index < 0) {
        snprintf(reply, replySize, "{\"ok\":false,\"error\":\"image not found after dlopen\"}");
        return;
    }
    RootTable fresh = collectRoots(
        (const struct mach_header_64 *)_dyld_get_image_header(index),
        _dyld_get_image_vmaddr_slide(index));

    int patched = 0, added = 0;
    for (size_t r = 0; r < fresh.count; r++) {
        Root *newRoot = &fresh.roots[r];
        int found = 0;
        for (int t = 0; t < targetCount; t++) {
            Root *old = bsearch(newRoot, targetRoots[t].roots, targetRoots[t].count,
                                sizeof(Root), compareRoots);
            if (!old) continue;
            old->addr[0] = newRoot->addr[0];
            found = 1;
            patched++;
        }
        if (!found) added++;
    }
    free(fresh.roots);
    addTarget((uint32_t)index);  // later patches must also redirect this one
    generation++;
    double done = nowMs();

    dispatch_async(dispatch_get_main_queue(), ^{
        CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                                             CFSTR("INJECTION_BUNDLE_NOTIFICATION"),
                                             NULL, NULL, true);
    });
    snprintf(reply, replySize,
             "{\"ok\":true,\"generation\":%d,\"patched\":%d,\"new\":%d,"
             "\"dlopenMs\":%.2f,\"patchMs\":%.2f}",
             generation, patched, added, loaded - start, done - loaded);
}

static void serve(int client) {
    FILE *in = fdopen(client, "r+");
    char line[PATH_MAX + 16];
    while (fgets(line, sizeof line, in)) {
        line[strcspn(line, "\r\n")] = 0;
        char reply[PATH_MAX + 256];
        if (strncmp(line, "load ", 5) == 0)
            loadPatch(line + 5, reply, sizeof reply);
        else
            snprintf(reply, sizeof reply, "{\"ok\":false,\"error\":\"unknown command\"}");
        LOG("%s -> %s\n", line, reply);
        fprintf(in, "%s\n", reply);
        fflush(in);
    }
    fclose(in);
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
