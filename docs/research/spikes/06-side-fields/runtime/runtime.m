#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <os/lock.h>
#include "runtime.h"

// The spike's stand-in for the agent: symbol lookup, chain-root copies, field-offset copies and the
// accessor jump (all of which Agent/Patcher.m does in the simulator), plus the side table itself.

// Finds a (hidden) symbol in the image whose path ends with `suffix`, or the main executable for NULL.
static void *symbol(const char *suffix, const char *name) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (suffix ? strlen(path) < strlen(suffix) || strcmp(path + strlen(path) - strlen(suffix), suffix)
                   : header->filetype != MH_EXECUTE) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *command = (const void *)(header + 1);
        const struct symtab_command *symtab = NULL;
        const struct segment_command_64 *linkedit = NULL;
        for (uint32_t c = 0; c < header->ncmds; c++, command = (const void *)((const char *)command + command->cmdsize)) {
            if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
            if (command->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname, "__LINKEDIT"))
                linkedit = (const void *)command;
        }
        if (!symtab || !linkedit) return NULL;
        const char *base = (const char *)(linkedit->vmaddr - linkedit->fileoff + slide);
        const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
        const char *strings = base + symtab->stroff;
        for (uint32_t s = 0; s < symtab->nsyms; s++)
            if (symbols[s].n_value && !strcmp(strings + symbols[s].n_un.n_strx + 1, name))
                return (void *)(symbols[s].n_value + slide);
        return NULL;
    }
    return NULL;
}

bool swp_repoint(const char *patchSuffix, const char *root) {
    void **old = symbol(NULL, root), **new = symbol(patchSuffix, root);
    if (!old || !new) return false;
    old[0] = new[0];
    return true;
}

// ── The side table ─────────────────────────────────────────────────────────────────────────
typedef struct {
    void *initializeBufferWithCopyOfBuffer;
    void (*destroy)(void *value, const void *type);
    void *initializeWithCopy, *assignWithCopy, *initializeWithTake, *assignWithTake;
    void *getEnumTagSinglePayload, *storeEnumTagSinglePayload;
    size_t size, stride;
    uint32_t flags, extraInhabitantCount;
} Witnesses;

extern const void *swift_getTypeByMangledNameInContext(const char *name, size_t length, const void *context,
                                                       const void *const *arguments);
static size_t mangledLength(const uint8_t *name) {
    const uint8_t *p = name;
    while (*p) p += *p <= 0x17 ? 5 : *p <= 0x1F ? 9 : 1;
    return (size_t)(p - name);
}

static int alive;
int swp_side_boxes_alive(void) { return alive; }

// One field's storage for one object, released with it as an associated object.
@interface SWPSideBox : NSObject {
@public
    void *storage;
    const void *type;
}
@end
@implementation SWPSideBox
- (void)dealloc {
    ((Witnesses *const *)type)[-1]->destroy(storage, type);
    free(storage);
    alive--;
    [super dealloc];
}
@end

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSValue *> *interned;

void *SWPSideField(void *object, const char *key, const char *typeName, const void *context, bool initializing, bool *fresh) {
    os_unfair_lock_lock(&lock);
    if (!interned) interned = [NSMutableDictionary new];
    NSString *name = @(key);
    // Every patch has its own copy of the key string; the side table keys by its content.
    const void *stable = interned[name].pointerValue;
    if (!stable) {
        stable = strdup(key);
        interned[name] = [NSValue valueWithPointer:stable];
    }
    SWPSideBox *box = objc_getAssociatedObject((id)object, stable);
    *fresh = false;
    if (!box) {
        const void *type = swift_getTypeByMangledNameInContext(typeName, mangledLength((const uint8_t *)typeName), context, NULL);
        const Witnesses *w = ((Witnesses *const *)type)[-1];
        box = [SWPSideBox new];
        box->type = type;
        posix_memalign(&box->storage, MAX((size_t)(w->flags & 0xFF) + 1, 16), MAX(w->size, 1));
        objc_setAssociatedObject((id)object, stable, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [box release];
        alive++;
        *fresh = !initializing;  // a designated initializer stores the first value itself
    }
    void *storage = box->storage;
    os_unfair_lock_unlock(&lock);
    return storage;
}

// What the agent does for field offsets set at metadata initialization: copy the app's value into the patch.
bool swp_copy_word(const char *patchSuffix, const char *name) {
    uint64_t *old = symbol(NULL, name), *new = symbol(patchSuffix, name);
    if (!old || !new) return false;
    *new = *old;
    return true;
}
long swp_word(const char *suffix, const char *name) { uint64_t *p = symbol(suffix, name); return p ? (long)*p : -1; }

// What the agent's accessor jump does: the patch's metadata accessor returns the app's metadata.
typedef struct { const void *metadata; long state; } SWPResponse;
SWPResponse swp_app_Model_Ma(long request) {
    static SWPResponse (*app)(long);
    if (!app) app = symbol(NULL, "$s3App5ModelCMa");
    return app(request);
}
