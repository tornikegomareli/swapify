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
//   ping                         -> {"ok":true,"generation":N}
//   load <absolute dylib path>   -> {"ok":true,"generation":N,...}
//   refresh                      -> re-renders every SwiftUI hosting view
//   ui                           -> visible accessibility elements as JSON
//   tap <label>                  -> activates the element with that label
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
    SymTable roots;        // $s...TX dynamic replacement chain roots
    SymTable accessors;    // $s...Ma type metadata accessors, $s...vau addressors
    SymTable descriptors;  // $s...Mn nominal type descriptors
    SymTable offsets;      // $s...Wvd field offsets, set during metadata init
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
    image.descriptors.syms = malloc(sizeof(Sym) * (symtab->nsyms + 1));
    image.offsets.syms = malloc(sizeof(Sym) * (symtab->nsyms + 1));
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
        else if (hasSuffix(name, "Mn"))
            image.descriptors.syms[image.descriptors.count++] = (Sym){name, addr};
        else if (hasSuffix(name, "Wvd"))
            image.offsets.syms[image.offsets.count++] = (Sym){name, addr};
    }
    qsort(image.roots.syms, image.roots.count, sizeof(Sym), compareNames);
    qsort(image.accessors.syms, image.accessors.count, sizeof(Sym), compareNames);
    qsort(image.descriptors.syms, image.descriptors.count, sizeof(Sym), compareNames);
    qsort(image.offsets.syms, image.offsets.count, sizeof(Sym), compareNames);
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

// Writes a 64-bit value, making the page writable first if needed.
static void writeWord(uintptr_t at, uint64_t value) {
    if (*(const uint64_t *)at == value) return;
    vm_address_t page = at & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t length = at + sizeof value - page;
    vm_protect(mach_task_self(), page, length, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    memcpy((void *)at, &value, sizeof value);
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

// Layout check. New code runs on objects with the old layout, so a patch must
// not change stored properties or a class vtable. Offsets below follow
// swift/ABI/Metadata.h (TargetClassDescriptor, TargetStructDescriptor,
// TargetEnumDescriptor, FieldDescriptor).
static const uint8_t *relative(const void *field) {
    int32_t offset;
    memcpy(&offset, field, sizeof offset);
    return offset ? (const uint8_t *)field + offset : NULL;
}

static const char *descriptorName(const uint8_t *descriptor) {
    const uint8_t *name = relative(descriptor + 8);
    return name ? (const char *)name : "";
}

// Compares two mangled type names. Symbolic references point into different
// images, so they are compared by the referenced descriptor's name.
static int sameMangledName(const uint8_t *a, const uint8_t *b) {
    while (*a && *b) {
        int aContext = *a == 0x01 || *a == 0x02, bContext = *b == 0x01 || *b == 0x02;
        if (aContext && bContext) {
            // Direct (01) and indirect (02) references to the same type are
            // equal; the linker picks one or the other.
            const uint8_t *da = relative(a + 1), *db = relative(b + 1);
            if (*a == 0x02) da = *(const uint8_t **)da;
            if (*b == 0x02) db = *(const uint8_t **)db;
            if (strcmp(descriptorName(da), descriptorName(db)) != 0) return 0;
            a += 5, b += 5;
            continue;
        }
        if (*a != *b) return 0;
        if (*a <= 0x17) a += 5, b += 5;       // other 4-byte relative references
        else if (*a <= 0x1F) a += 9, b += 9;  // pointer-sized absolute references
        else a++, b++;
    }
    return *a == *b;
}

// Returns NULL if both descriptors describe the same stored layout, otherwise
// the reason they differ.
static const char *layoutDifference(const uint8_t *old, const uint8_t *new) {
    static char reason[160];
    uint32_t kind = *(const uint32_t *)old & 0x1F;
    if (kind != (*(const uint32_t *)new & 0x1F)) return "kind";
    if (kind == 16) {  // class: metadata bounds, vtable members, field count and offset
        for (int offset = 24; offset < 44; offset += 4)
            if (*(const uint32_t *)(old + offset) != *(const uint32_t *)(new + offset)) {
                snprintf(reason, sizeof reason, "class descriptor word at %d: %u -> %u", offset,
                         *(const uint32_t *)(old + offset), *(const uint32_t *)(new + offset));
                return reason;
            }
    } else if (kind == 17 || kind == 18) {  // struct, enum
        if (memcmp(old + 20, new + 20, 8) != 0) return "field count or payload layout";
    } else {
        return NULL;
    }
    const uint8_t *oldFields = relative(old + 16), *newFields = relative(new + 16);
    if (!oldFields || !newFields) return oldFields == newFields ? NULL : "field descriptor";
    uint32_t count = *(const uint32_t *)(oldFields + 12);
    if (count != *(const uint32_t *)(newFields + 12)) return "field count";
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *a = oldFields + 16 + 12 * i, *b = newFields + 16 + 12 * i;
        const uint8_t *aName = relative(a + 8), *bName = relative(b + 8);
        const char *name = aName ? (const char *)aName : "?";
        if (strcmp(name, bName ? (const char *)bName : "") != 0) {
            snprintf(reason, sizeof reason, "field %u renamed: %s", i, name);
            return reason;
        }
        if (*(const uint32_t *)a != *(const uint32_t *)b) {
            snprintf(reason, sizeof reason, "field %s: let/var changed", name);
            return reason;
        }
        const uint8_t *aType = relative(a + 4), *bType = relative(b + 4);
        if ((aType == NULL) != (bType == NULL) || (aType && !sameMangledName(aType, bType))) {
            snprintf(reason, sizeof reason, "field %s: type changed", name);
            return reason;
        }
    }
    return NULL;
}

// Returns the mangled name of the first type whose layout changed, or NULL.
static const char *changedLayout(Image *fresh, const char **reason) {
    for (size_t i = 0; i < fresh->descriptors.count; i++) {
        Sym *newSym = &fresh->descriptors.syms[i];
        for (int t = 0; t < appImageCount; t++) {
            Sym *old = lookup(&targets[t].descriptors, newSym->name);
            if (!old) continue;
            *reason = layoutDifference((const uint8_t *)old->addr, (const uint8_t *)newSym->addr);
            if (*reason) return newSym->name + 1;  // drop the leading underscore
            break;
        }
    }
    return NULL;
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

    // The dylib stays loaded but inert: nothing points at its code.
    const char *reason = NULL;
    const char *changed = changedLayout(&fresh, &reason);
    if (changed) {
        snprintf(reply, replySize,
                 "{\"ok\":false,\"needsRebuild\":true,\"error\":\"stored layout changed\","
                 "\"type\":\"%s\",\"reason\":\"%s\"}", changed, reason);
        return;
    }

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

    // Field offsets of types whose layout depends on other modules are
    // computed when the metadata is initialized. The patch's metadata never
    // initializes (its accessors jump to the app's), so copy the app's values.
    for (size_t i = 0; i < fresh.offsets.count; i++) {
        Sym *newSym = &fresh.offsets.syms[i];
        for (int t = 0; t < appImageCount; t++) {
            Sym *old = lookup(&targets[t].offsets, newSym->name);
            if (!old) continue;
            writeWord(newSym->addr, *(const uint64_t *)old->addr);
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
    free(fresh.descriptors.syms);
    free(fresh.offsets.syms);
    fresh.accessors = fresh.descriptors = fresh.offsets = (SymTable){0};
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

// UI inspection through the public accessibility API. SwiftUI hosting views
// expose their elements as accessibility containers.
static NSArray *accessibilityChildren(id node) {
    NSArray *children = [node accessibilityElements];
    if (children.count) return children;
    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0) {
        NSMutableArray *list = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            id child = [node accessibilityElementAtIndex:i];
            if (child) [list addObject:child];
        }
        return list;
    }
    return [node isKindOfClass:UIView.class] ? ((UIView *)node).subviews : @[];
}

static void collectElements(id node, NSMutableArray *out, int depth) {
    if (depth > 80) return;
    if ([node isKindOfClass:UIView.class] && ((UIView *)node).hidden) return;
    if ([node isAccessibilityElement]) [out addObject:node];
    for (id child in accessibilityChildren(node)) collectElements(child, out, depth + 1);
}

// SwiftUI builds its accessibility tree only when accessibility is on.
// Returns 1 if this call turned it on.
static int enableAccessibility(void) {
    static int enabled;
    if (enabled) return 0;
    enabled = 1;
    void (*setEnabled)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    if (!setEnabled) {
        dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        setEnabled = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    }
    if (setEnabled) setEnabled(1);
    else LOG("_AXSApplicationAccessibilitySetEnabled not found\n");
    return 1;
}

static NSArray *visibleElements(void) {
    NSMutableArray *elements = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *window in ((UIWindowScene *)scene).windows)
                if (!window.hidden) collectElements(window, elements, 0);
    return elements;
}

static NSDictionary *describeElement(id element) {
    UIAccessibilityTraits traits = [element accessibilityTraits];
    NSMutableArray *names = [NSMutableArray array];
    if (traits & UIAccessibilityTraitButton) [names addObject:@"button"];
    if (traits & UIAccessibilityTraitHeader) [names addObject:@"header"];
    if (traits & UIAccessibilityTraitSelected) [names addObject:@"selected"];
    if (traits & UIAccessibilityTraitStaticText) [names addObject:@"text"];
    if (traits & UIAccessibilityTraitImage) [names addObject:@"image"];
    if (traits & UIAccessibilityTraitNotEnabled) [names addObject:@"disabled"];
    CGRect frame = [element accessibilityFrame];
    return @{
        @"label" : [element accessibilityLabel] ?: @"",
        @"value" : [element accessibilityValue] ?: @"",
        @"traits" : names,
        @"frame" : @[ @(round(frame.origin.x)), @(round(frame.origin.y)),
                      @(round(frame.size.width)), @(round(frame.size.height)) ],
    };
}

static NSDictionary *describeUI(void) {
    NSMutableArray *list = [NSMutableArray array];
    for (id element in visibleElements()) [list addObject:describeElement(element)];
    // Tree order can lag behind the screen, so sort top to bottom, left to right.
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSArray *fa = a[@"frame"], *fb = b[@"frame"];
        NSComparisonResult byY = [fa[1] compare:fb[1]];
        return byY != NSOrderedSame ? byY : [fa[0] compare:fb[0]];
    }];
    return @{@"ok" : @YES, @"elements" : list};
}

// Activates the first element whose label equals `label`, else the first
// whose label contains it.
static NSDictionary *tapElement(NSString *label) {
    NSArray *elements = visibleElements();
    id target = nil;
    for (id element in elements)
        if ([[element accessibilityLabel] isEqualToString:label]) { target = element; break; }
    if (!target)
        for (id element in elements)
            if ([[element accessibilityLabel] containsString:label]) { target = element; break; }
    if (!target) return @{@"ok" : @NO, @"error" : @"no element with that label"};
    BOOL activated = [target accessibilityActivate];
    return @{@"ok" : @(activated), @"element" : describeElement(target)};
}

static NSString *jsonString(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *handle(NSString *line) {
    if ([line isEqualToString:@"ping"])
        return [NSString stringWithFormat:@"{\"ok\":true,\"generation\":%d}", generation];
    if ([line hasPrefix:@"load "]) {
        char reply[PATH_MAX + 256];
        loadPatch([line substringFromIndex:5].UTF8String, reply, sizeof reply);
        return @(reply);
    }
    __block NSDictionary *result = nil;
    if ([line isEqualToString:@"ui"] || [line hasPrefix:@"tap "]) {
        __block int justEnabled = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{ justEnabled = enableAccessibility(); });
        if (justEnabled) usleep(500 * 1000);  // let SwiftUI build the tree
    }
    if ([line isEqualToString:@"refresh"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            double start = nowMs();
            int hosts = refreshSwiftUI();
            result = @{@"ok" : @(hosts >= 0), @"hosts" : @(hosts), @"refreshMs" : @(nowMs() - start)};
        });
    } else if ([line isEqualToString:@"ui"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ result = describeUI(); });
    } else if ([line hasPrefix:@"tap "]) {
        NSString *label = [line substringFromIndex:4];
        dispatch_sync(dispatch_get_main_queue(), ^{ result = tapElement(label); });
    } else {
        result = @{@"ok" : @NO, @"error" : @"unknown command"};
    }
    return jsonString(result);
}

static void serve(int client) {
    FILE *io = fdopen(client, "r+");
    char line[PATH_MAX + 16];
    while (fgets(line, sizeof line, io)) {
        line[strcspn(line, "\r\n")] = 0;
        @autoreleasepool {
            NSString *reply = handle(@(line));
            LOG("%s -> %.200s\n", line, reply.UTF8String);
            fprintf(io, "%s\n", reply.UTF8String);
            fflush(io);
        }
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
