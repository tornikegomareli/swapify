// SwapifyAgent: the in-app half of swapify. It is inserted into a Debug
// simulator app with DYLD_INSERT_LIBRARIES and serves the wire protocol in
// docs/protocol.md. Everything here is internal: the dylib is built with
// -fvisibility=hidden, and internal functions use the SWP prefix.
#import <UIKit/UIKit.h>

#define SWP_PROTOCOL_VERSION 1
#define SWP_LOG(...) fprintf(stderr, "[swapify] " __VA_ARGS__)

double SWPNowMs(void);

// Images.m: symbol tables of loaded Mach-O images.
typedef struct {
    const char *name;
    uintptr_t address;
} SWPSymbol;

typedef struct {
    SWPSymbol *symbols;  // sorted by name
    size_t count;
} SWPSymbolTable;

typedef struct {
    SWPSymbolTable roots;          // $s...TX  dynamic replacement chain roots
    SWPSymbolTable accessors;      // $s...Ma, $s...vau, $s...Wl, $s...Wa
    SWPSymbolTable descriptors;    // $s...Mn  nominal type descriptors
    SWPSymbolTable fieldOffsets;   // $s...Wvd field offsets, set at metadata init
    SWPSymbolTable witnessTables;  // $s...WP  protocol witness tables
    SWPSymbolTable metadata;       // $s...VN, $s...CN, $s...ON  type metadata
    SWPSymbolTable metadataSlots;  // swapify.meta.$s...N  a patch's references to static metadata
} SWPImage;

// Reads the image's symbols, local symbols included. If `addresses` is set, it
// also returns every defined symbol address, sorted, so callers can measure
// symbol sizes.
SWPImage SWPImageRead(uint32_t index, uintptr_t **addresses, size_t *count);
SWPSymbol *SWPSymbolTableLookup(const SWPSymbolTable *table, const char *name);
void SWPSymbolTableFree(SWPSymbolTable *table);
int SWPImageIndex(const char *path, uint32_t first);

// Memory.m: writes into loaded images.
BOOL SWPWriteJump(uintptr_t at, uintptr_t to);
void SWPWriteWord(uintptr_t at, uint64_t value);

// Layout.m: compares two nominal type descriptors.
const char *SWPLayoutDifference(const uint8_t *old, const uint8_t *new);

// Patcher.m: loads patches.
void SWPPatcherStart(void);
// `sideTypes` names the descriptors ($s…Mn) of classes whose layout changes the CLI
// moved to side storage (SideFields.m); the layout guard skips them.
NSDictionary *SWPPatcherLoad(NSString *path, NSSet<NSString *> *sideTypes);
int SWPPatcherGeneration(void);

// SwiftUIRefresh.m: re-renders SwiftUI. Main thread only.
BOOL SWPSwiftUILoaded(void);
BOOL SWPSwiftUIRefreshAvailable(void);
NSDictionary *SWPSwiftUIRefresh(void);

// Inspector.m: accessibility tree, taps and snapshots. Main thread only.
BOOL SWPEnableAccessibility(void);
NSDictionary *SWPDescribeUI(void);
NSDictionary *SWPTap(NSString *label);
NSDictionary *SWPSnapshot(NSString *path, CGFloat scale);
