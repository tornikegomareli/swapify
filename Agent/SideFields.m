#import "Agent.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>

// Stored properties that a patch adds to a class the app was built with. Objects keep
// the layout they were made with. Each new field lives in a block of memory attached
// to the object as an associated object, so it is released with the object. The patch
// reaches the block through SWPSideField: SideFields.swift rewrites every access to
// the new field into a call to it. See docs/research/spikes/06-side-fields.

// swift/ABI/ValueWitness.def: the value witness table before a type's metadata.
typedef struct {
    void *initializeBufferWithCopyOfBuffer;
    void (*destroy)(void *value, const void *type);
    void *initializeWithCopy, *assignWithCopy, *initializeWithTake, *assignWithTake;
    void *getEnumTagSinglePayload, *storeEnumTagSinglePayload;
    size_t size, stride;
    uint32_t flags, extraInhabitantCount;
} SWPValueWitnesses;

// From the Swift runtime, which every Swift app has loaded. The agent does not link it.
typedef const void *(*SWPTypeByName)(const char *name, size_t length, const void *context, const void *const *arguments);

static SWPTypeByName typeByName(void) {
    static SWPTypeByName function;
    if (!function) function = (SWPTypeByName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    return function;
}

static const SWPValueWitnesses *witnesses(const void *type) { return ((const SWPValueWitnesses *const *)type)[-1]; }

// A mangled name's length: symbolic references hold 4 or 8 bytes that can be zero.
static size_t mangledLength(const uint8_t *name) {
    const uint8_t *p = name;
    while (*p) p += *p <= 0x17 ? 5 : *p <= 0x1F ? 9 : 1;
    return (size_t)(p - name);
}

// One field of one object. `ready` once its first value is stored.
@interface SWPSideBox : NSObject {
@public
    void *storage;
    const void *type;
    BOOL ready;
}
@end

@implementation SWPSideBox
- (void)dealloc {
    if (ready) witnesses(type)->destroy(storage, type);
    free(storage);
}
@end

// One lock for every box; `stored` wakes threads that wait for a first value.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t stored = PTHREAD_COND_INITIALIZER;

// Every patch has its own copy of a key's string. The association key is one pointer
// per string content, so a later patch finds the storage an earlier one made.
static const void *internedKey(const char *key) {
    static NSMutableDictionary<NSString *, NSValue *> *keys;
    if (!keys) keys = [NSMutableDictionary new];
    NSString *name = @(key);
    NSValue *known = keys[name];
    if (known) return known.pointerValue;
    const void *pointer = strdup(key);
    keys[name] = [NSValue valueWithPointer:pointer];
    return pointer;
}

// The address of field `key` ("<type>.<field>#<field type>") of `object`. `typeName` is
// the field's mangled type, resolved in `context`, the descriptor of the type that
// declares it. The first call for an object and field makes the storage and sets
// *fresh: the patch stores the field's initial value there, then calls
// SWPSideFieldReady. Meanwhile other threads wait here. A designated initializer passes
// `initializing`, because it stores the first value of its own object itself.
__attribute__((visibility("default"))) void *SWPSideField(void *object, const char *key, const char *typeName,
                                                          const void *context, int initializing, bool *fresh) {
    pthread_mutex_lock(&lock);
    const void *stable = internedKey(key);
    id target = (__bridge id)object;
    SWPSideBox *box = objc_getAssociatedObject(target, stable);
    *fresh = false;
    if (!box) {
        const void *type = typeByName()(typeName, mangledLength((const uint8_t *)typeName), context, NULL);
        const SWPValueWitnesses *w = witnesses(type);
        box = [SWPSideBox new];
        box->type = type;
        if (posix_memalign(&box->storage, MAX((size_t)(w->flags & 0xFF) + 1, 16), MAX(w->size, 1)) != 0) abort();
        box->ready = initializing != 0;
        objc_setAssociatedObject(target, stable, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        *fresh = !initializing;
    } else {
        while (!box->ready) pthread_cond_wait(&stored, &lock);
    }
    void *storage = box->storage;
    pthread_mutex_unlock(&lock);
    return storage;
}

// The first value of a fresh field is stored: other threads may read it now.
__attribute__((visibility("default"))) void SWPSideFieldReady(void *object, const char *key) {
    pthread_mutex_lock(&lock);
    SWPSideBox *box = objc_getAssociatedObject((__bridge id)object, internedKey(key));
    box->ready = YES;
    pthread_cond_broadcast(&stored);
    pthread_mutex_unlock(&lock);
}
