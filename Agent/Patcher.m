#import "Agent.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>

// A patch is one or more edited Swift files, compiled unchanged with the app's
// own frontend command and linked into a dylib. Making it live takes two
// directions of redirection:
//
//   new -> old  The patch defines its own copy of every type, static and
//               conformance in the edited files. New code must keep using the
//               app's originals, so the patch's metadata accessors and
//               addressors jump to the app's, and the app's field offsets and
//               witness tables are copied into the patch.
//   old -> new  With -enable-implicit-dynamic every Swift function starts by
//               reading its dynamic replacement chain root ($s...TX). Copying
//               the patch's root into the app's root makes old callers run the
//               new body.
//
// See docs/architecture.md.

static SWPImage images[512];  // app images first, then loaded patches
static int imageCount, appImageCount, generation;

int SWPPatcherGeneration(void) { return generation; }

// App images: every image in the main executable's directory, which includes
// the Xcode debug dylib and embedded frameworks.
void SWPPatcherStart(void) {
    char directory[PATH_MAX] = "";
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i)->filetype == MH_EXECUTE)
            strlcpy(directory, _dyld_get_image_name(i), sizeof directory);
    char *slash = strrchr(directory, '/');
    if (slash) slash[1] = 0;
    for (uint32_t i = 0; i < _dyld_image_count() && imageCount < 256; i++)
        if (strncmp(_dyld_get_image_name(i), directory, strlen(directory)) == 0)
            images[imageCount++] = SWPImageRead(i, NULL, NULL);
    appImageCount = imageCount;
}

// The runtime name of the class a function belongs to, for a top-level Swift class:
// "_$s5Notes18ListViewControllerC4loadyyFTX" -> "_TtC5Notes18ListViewController", and a
// private one: "_$s5Notes4Cell33_<32 hex>LLC…" -> "_TtC5NotesP33_<32 hex>4Cell".
static NSString *classOfFunction(const char *root);

// A Swift class has two runtime names: symbols give the mangled one, "_TtC5Notes4Cell", and
// class_getName the demangled one, "Notes.Cell". This returns the one class_getName gives.
static NSString *runtimeName(NSString *name) {
    Class found = objc_lookUpClass(name.UTF8String);
    return found ? @(class_getName(found)) : name;
}

static NSString *classOfFunction(const char *root) {
    if (strncmp(root, "_$s", 3) != 0) return nil;
    const char *p = root + 3, *module = p, *name = NULL;
    for (int part = 0; part < 2; part++) {  // the module, then the type
        if (*p < '1' || *p > '9') return nil;
        char *end;
        long length = strtol(p, &end, 10);
        if ((long)strlen(end) <= length) return nil;
        if (part == 1) name = p;
        p = end + length;
    }
    if (*p == 'C') return [NSString stringWithFormat:@"_TtC%.*s", (int)(p - module), module];
    if (strncmp(p, "33_", 3) == 0 && strlen(p) > 38 && strncmp(p + 35, "LLC", 3) == 0)
        return [NSString stringWithFormat:@"_TtC%.*sP%.*s%.*s", (int)(name - module), module, 35, p,
                                          (int)(p - name), name];
    return nil;
}

// Methods the Objective-C runtime must not take from a patch: the ivar destroyer and
// dealloc destroy fields by the patch's layout, and deinit is not reloaded.
static BOOL keepsAppMethod(SEL selector) {
    const char *name = sel_getName(selector);
    return !strcmp(name, ".cxx_destruct") || !strcmp(name, ".cxx_construct") || !strcmp(name, "dealloc");
}

// The app's definition of `name` in the table at `offset` inside SWPImage.
static SWPSymbol *original(size_t offset, const char *name) {
    for (int i = 0; i < appImageCount; i++) {
        SWPSymbolTable *table = (SWPSymbolTable *)((char *)&images[i] + offset);
        SWPSymbol *symbol = SWPSymbolTableLookup(table, name);
        if (symbol) return symbol;
    }
    return NULL;
}

// device: these three helpers are __unused on a device, which skips the jumps, copies and guard.
__unused static size_t symbolSize(uintptr_t address, const uintptr_t *addresses, size_t count) {
    for (size_t i = 0; i < count; i++)
        if (addresses[i] > address) return addresses[i] - address;
    return 0;
}

// Words in a witness table: the conformance descriptor plus one per protocol
// requirement (TargetProtocolDescriptor.NumRequirements at offset 16).
__unused static size_t witnessTableWords(uintptr_t table) {
    const uint8_t *conformance = *(const uint8_t *const *)table;
    if (!conformance) return 0;
    int32_t offset;
    memcpy(&offset, conformance, sizeof offset);  // relative indirectable pointer
    const uint8_t *protocol = conformance + (offset & ~1);
    if (offset & 1) protocol = *(const uint8_t *const *)protocol;
    return protocol ? 1 + *(const uint32_t *)(protocol + 16) : 0;
}

__unused static NSDictionary *checkLayouts(const SWPImage *patch, NSSet<NSString *> *sideTypes) {
    for (size_t i = 0; i < patch->descriptors.count; i++) {
        SWPSymbol *symbol = &patch->descriptors.symbols[i];
        SWPSymbol *old = original(offsetof(SWPImage, descriptors), symbol->name);
        if (!old || [sideTypes containsObject:@(symbol->name + 1)]) continue;
        const char *reason = SWPLayoutDifference((const uint8_t *)old->address,
                                                 (const uint8_t *)symbol->address);
        if (reason)
            return @{@"ok" : @NO, @"needsRebuild" : @YES, @"error" : @"layout changed",
                     @"type" : @(symbol->name + 1), @"reason" : @(reason)};
    }
    return nil;
}

NSDictionary *SWPPatcherLoad(NSString *path, NSSet<NSString *> *sideTypes) {
    double start = SWPNowMs();
    uint32_t imagesBefore = _dyld_image_count();
    if (!dlopen(path.UTF8String, RTLD_NOW))
        return @{@"ok" : @NO, @"error" : @(dlerror() ?: "dlopen failed")};
    double loaded = SWPNowMs();
    int index = SWPImageIndex(path.UTF8String, imagesBefore);
    if (index < 0) return @{@"ok" : @NO, @"error" : @"patch image not found after dlopen"};
    if (imageCount >= (int)(sizeof images / sizeof *images))
        return @{@"ok" : @NO, @"needsRebuild" : @YES, @"error" : @"too many patches; relaunch the app"};

    uintptr_t *addresses;
    size_t addressCount;
    SWPImage patch = SWPImageRead((uint32_t)index, &addresses, &addressCount);

    int accessors = 0, tooSmall = 0, witnessTables = 0, sharedMetadata = 0, objcAdded = 0;
    // Classes with @objc members, which have Objective-C thunks `$s…To`: NSObject
    // subclasses, such as every UIKit class. Only their method lists are read. A pure Swift
    // class has none, and reading its metadata before it is initialized is not safe.
    NSMutableSet<NSString *> *objcClasses = [NSMutableSet set], *objcNames = [NSMutableSet set];
    for (size_t i = 0; i < patch.objcThunks.count; i++) {
        NSString *owner = classOfFunction(patch.objcThunks.symbols[i].name);
        if (owner && ![objcClasses containsObject:owner]) {
            [objcClasses addObject:owner];
            [objcNames addObject:runtimeName(owner)];
        }
    }
#if TARGET_OS_SIMULATOR
    // device: skipped on a device. A device patch is bound to the app's types by dyld (see
    // docs/research/spikes/04-device-bind) and defines none of them, so there is nothing to jump,
    // copy or compare, and code pages cannot be written there. The layout guard must move to the
    // Mac for devices.

    // A rejected patch stays loaded but inert: nothing points at its code.
    NSDictionary *rejection = checkLayouts(&patch, sideTypes);
    if (rejection) {
        free(addresses);
        return rejection;
    }

    // New -> old. This runs before any patch code can run.
    for (size_t i = 0; i < patch.accessors.count; i++) {
        SWPSymbol *symbol = &patch.accessors.symbols[i];
        SWPSymbol *old = original(offsetof(SWPImage, accessors), symbol->name);
        if (!old) continue;
        if (symbolSize(symbol->address, addresses, addressCount) < 16) tooSmall++;
        else if (SWPWriteJump(symbol->address, old->address)) accessors++;
    }
    // Code that names a type's static metadata directly reads it from a slot
    // (MetadataSlots.swift). A type the app has gets the app's metadata: the patch's
    // copy would be a second type, which SwiftUI cannot cast to the app's (issue #7).
    // A type new since the build keeps the patch's own.
    for (size_t i = 0; i < patch.metadataSlots.count; i++) {
        SWPSymbol *slot = &patch.metadataSlots.symbols[i];
        char name[1024];
        snprintf(name, sizeof name, "_%s", slot->name + strlen("_swapify.meta."));
        SWPSymbol *old = original(offsetof(SWPImage, metadata), name);
        if (!old) continue;
        SWPWriteWord(slot->address, old->address);
        sharedMetadata++;
    }
    // Methods new in the edit, such as a new action, from the patch's own copy of each
    // class. A device patch registers no classes, so there a new @objc method needs a
    // rebuild. Reading a class's methods realizes it, and realizing a class whose layout
    // depends on an Objective-C superclass sets its field offsets, so this runs before the
    // app's field offsets are copied into the patch.
    unsigned long listSize = 0;
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header((uint32_t)index);
    uint8_t *section = getsectiondata(header, "__DATA", "__objc_classlist", &listSize);
    if (!section) section = getsectiondata(header, "__DATA_CONST", "__objc_classlist", &listSize);
    void *const *list = (void *const *)section;
    for (size_t k = 0; list && k < listSize / sizeof(void *); k++) {
        Class mine = (__bridge Class)list[k];
        if (![objcNames containsObject:@(class_getName(mine))]) continue;
        Class app = objc_getClass(class_getName(mine));
        if (!app || app == mine) continue;  // a class new in the patch
        for (int meta = 0; meta < 2; meta++) {
            Class from = meta ? object_getClass(mine) : mine, to = meta ? object_getClass(app) : app;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(from, &count);
            for (unsigned int m = 0; m < count; m++)
                if (!keepsAppMethod(method_getName(methods[m])) &&
                    class_addMethod(to, method_getName(methods[m]), method_getImplementation(methods[m]),
                                    method_getTypeEncoding(methods[m])))
                    objcAdded++;
            free(methods);
        }
    }
    // Field offsets of types whose layout depends on other modules are set
    // when metadata initializes. The patch's metadata never initializes.
    for (size_t i = 0; i < patch.fieldOffsets.count; i++) {
        SWPSymbol *symbol = &patch.fieldOffsets.symbols[i];
        SWPSymbol *old = original(offsetof(SWPImage, fieldOffsets), symbol->name);
        if (old) SWPWriteWord(symbol->address, *(const uint64_t *)old->address);
    }
    // The patch's witness tables name the patch's conformance descriptors,
    // which do not match the app's metadata. Their function entries still
    // reach the new code through chain roots.
    for (size_t i = 0; i < patch.witnessTables.count; i++) {
        SWPSymbol *symbol = &patch.witnessTables.symbols[i];
        SWPSymbol *old = original(offsetof(SWPImage, witnessTables), symbol->name);
        if (!old) continue;
        size_t words = witnessTableWords(old->address);
        if (!words || words != witnessTableWords(symbol->address)) continue;
        for (size_t w = 0; w < words; w++)
            SWPWriteWord(symbol->address + 8 * w, ((const uint64_t *)old->address)[w]);
        witnessTables++;
    }
#else
    // A device patch registers no classes, so a new @objc member of an app class cannot get
    // into it: the first call through its selector would end the app.
    for (size_t i = 0; i < patch.objcThunks.count; i++) {
        const char *name = patch.objcThunks.symbols[i].name;
        NSString *owner = classOfFunction(name);
        if (!owner || !objc_lookUpClass(owner.UTF8String) || original(offsetof(SWPImage, objcThunks), name)) continue;
        free(addresses);
        NSString *reason = [NSString stringWithFormat:@"%@ has a new @objc method or property. On a device that needs a rebuild.",
                                                      runtimeName(owner)];
        return @{@"ok" : @NO, @"needsRebuild" : @YES, @"reason" : reason, @"error" : reason};
    }
#endif

    // Old -> new: for each function the app has, the app and every earlier patch
    // forward to this patch. A function only patches define (one of a type that is
    // new since the build) stays as it is in earlier patches: each patch compiles
    // every file changed since the build, so its code only meets its own copy of
    // such a type, and an earlier patch's code only meets the earlier copy.
    int replaced = 0, added = 0;
    // The classes this patch touches, for the UIKit refresh: those it defines, and those
    // whose methods it replaces (an extension in another file, or a bound device patch).
    NSMutableSet<NSString *> *classes = [NSMutableSet set];
    unsigned int classCount = 0;
    const char **classNames = objc_copyClassNamesForImage(_dyld_get_image_name((uint32_t)index), &classCount);
    for (unsigned int i = 0; i < classCount; i++) [classes addObject:@(classNames[i])];
    free(classNames);
    NSMutableSet<NSString *> *owners = [NSMutableSet set];
    for (size_t i = 0; i < patch.roots.count; i++) {
        SWPSymbol *root = &patch.roots.symbols[i];
        if (!original(offsetof(SWPImage, roots), root->name)) {
            added++;
            continue;
        }
        NSString *owner = classOfFunction(root->name);
        if (owner && ![owners containsObject:owner]) {
            [owners addObject:owner];
            [classes addObject:runtimeName(owner)];
        }
        for (int t = 0; t < imageCount; t++) {
            SWPSymbol *old = SWPSymbolTableLookup(&images[t].roots, root->name);
            if (!old) continue;
            ((void **)old->address)[0] = ((void **)root->address)[0];
            replaced++;
        }
    }

    // @objc members. UIKit calls overrides such as viewDidLoad, data source and delegate
    // methods, and target-actions through the Objective-C runtime, and
    // -enable-implicit-dynamic gives @objc members no chain root. So in each class the patch
    // touches, a method whose implementation is a thunk `$s…To` (the app's, or an earlier
    // patch's) gets the patch's thunk of the same name, which calls the new body.
    [classes unionSet:objcNames];
    NSMutableDictionary<NSNumber *, NSString *> *thunks = [NSMutableDictionary dictionary];
    for (int t = 0; t < imageCount; t++)
        for (size_t i = 0; i < images[t].objcThunks.count; i++)
            thunks[@(images[t].objcThunks.symbols[i].address)] = @(images[t].objcThunks.symbols[i].name);
    int objcReplaced = 0;
    for (NSString *name in objcClasses) {
        Class app = objc_getClass(name.UTF8String);
        for (Class c = app; c; c = c == app ? object_getClass(app) : Nil) {  // the class, then its metaclass
            unsigned int count = 0;
            Method *methods = class_copyMethodList(c, &count);
            for (unsigned int m = 0; m < count; m++) {
                if (keepsAppMethod(method_getName(methods[m]))) continue;
                NSString *thunk = thunks[@((uintptr_t)method_getImplementation(methods[m]))];
                SWPSymbol *fresh = thunk ? SWPSymbolTableLookup(&patch.objcThunks, thunk.UTF8String) : NULL;
                if (fresh && fresh->address != (uintptr_t)method_getImplementation(methods[m])) {
                    method_setImplementation(methods[m], (IMP)fresh->address);
                    objcReplaced++;
                }
            }
            free(methods);
        }
    }

    free(addresses);
    SWPSymbolTableFree(&patch.accessors);
    SWPSymbolTableFree(&patch.descriptors);
    SWPSymbolTableFree(&patch.fieldOffsets);
    SWPSymbolTableFree(&patch.witnessTables);
    SWPSymbolTableFree(&patch.metadata);
    SWPSymbolTableFree(&patch.metadataSlots);
    images[imageCount++] = patch;  // keep its roots for the next patch
    generation++;
    double done = SWPNowMs();

    int current = generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        SWPUIKitSetPatchedClasses(classes);
        // SwapifyDidReload is ours; INJECTION_BUNDLE_NOTIFICATION keeps
        // Inject's @ObserveInjection working.
        [NSNotificationCenter.defaultCenter postNotificationName:@"SwapifyDidReload"
                                                          object:nil
                                                        userInfo:@{@"generation" : @(current)}];
        [NSNotificationCenter.defaultCenter postNotificationName:@"INJECTION_BUNDLE_NOTIFICATION"
                                                          object:nil];
    });
    return @{
        @"ok" : @YES, @"generation" : @(generation), @"replaced" : @(replaced), @"added" : @(added),
        @"sharedAccessors" : @(accessors), @"sharedWitnessTables" : @(witnessTables), @"sharedMetadata" : @(sharedMetadata),
        @"objcReplaced" : @(objcReplaced), @"objcAdded" : @(objcAdded),
        @"tooSmall" : @(tooSmall), @"dlopenMs" : @(loaded - start), @"patchMs" : @(done - loaded),
    };
}
