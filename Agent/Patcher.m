#import "Agent.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

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

__unused static NSDictionary *checkLayouts(const SWPImage *patch) {
    for (size_t i = 0; i < patch->descriptors.count; i++) {
        SWPSymbol *symbol = &patch->descriptors.symbols[i];
        SWPSymbol *old = original(offsetof(SWPImage, descriptors), symbol->name);
        if (!old) continue;
        const char *reason = SWPLayoutDifference((const uint8_t *)old->address,
                                                 (const uint8_t *)symbol->address);
        if (reason)
            return @{@"ok" : @NO, @"needsRebuild" : @YES, @"error" : @"layout changed",
                     @"type" : @(symbol->name + 1), @"reason" : @(reason)};
    }
    return nil;
}

NSDictionary *SWPPatcherLoad(NSString *path) {
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

    int accessors = 0, tooSmall = 0, witnessTables = 0;
#if TARGET_OS_SIMULATOR
    // device: skipped on a device. A device patch is bound to the app's types by dyld (see
    // docs/research/spikes/04-device-bind) and defines none of them, so there is nothing to jump,
    // copy or compare, and code pages cannot be written there. The layout guard must move to the
    // Mac for devices.

    // A rejected patch stays loaded but inert: nothing points at its code.
    NSDictionary *rejection = checkLayouts(&patch);
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
#endif

    // Old -> new: the app and every earlier patch forward to this patch.
    int replaced = 0, added = 0;
    for (size_t i = 0; i < patch.roots.count; i++) {
        SWPSymbol *root = &patch.roots.symbols[i];
        BOOL found = NO;
        for (int t = 0; t < imageCount; t++) {
            SWPSymbol *old = SWPSymbolTableLookup(&images[t].roots, root->name);
            if (!old) continue;
            ((void **)old->address)[0] = ((void **)root->address)[0];
            found = YES;
            replaced++;
        }
        if (!found) added++;
    }

    free(addresses);
    SWPSymbolTableFree(&patch.accessors);
    SWPSymbolTableFree(&patch.descriptors);
    SWPSymbolTableFree(&patch.fieldOffsets);
    SWPSymbolTableFree(&patch.witnessTables);
    images[imageCount++] = patch;  // keep its roots for the next patch
    generation++;
    double done = SWPNowMs();

    int current = generation;
    dispatch_async(dispatch_get_main_queue(), ^{
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
        @"sharedAccessors" : @(accessors), @"sharedWitnessTables" : @(witnessTables),
        @"tooSmall" : @(tooSmall), @"dlopenMs" : @(loaded - start), @"patchMs" : @(done - loaded),
    };
}
