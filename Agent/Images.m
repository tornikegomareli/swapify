#import "Agent.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

static BOOL hasSuffix(const char *string, const char *suffix) {
    size_t n = strlen(string), m = strlen(suffix);
    return n > m && strcmp(string + n - m, suffix) == 0;
}

static int compareNames(const void *a, const void *b) {
    return strcmp(((const SWPSymbol *)a)->name, ((const SWPSymbol *)b)->name);
}

static int compareAddresses(const void *a, const void *b) {
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return x < y ? -1 : x > y;
}

SWPSymbol *SWPSymbolTableLookup(const SWPSymbolTable *table, const char *name) {
    SWPSymbol key = {name, 0};
    return bsearch(&key, table->symbols, table->count, sizeof(SWPSymbol), compareNames);
}

void SWPSymbolTableFree(SWPSymbolTable *table) {
    free(table->symbols);
    *table = (SWPSymbolTable){0};
}

static void append(SWPSymbolTable *table, const char *name, uintptr_t address) {
    table->symbols[table->count++] = (SWPSymbol){name, address};
}

static void sort(SWPSymbolTable *table) {
    qsort(table->symbols, table->count, sizeof(SWPSymbol), compareNames);
}

SWPImage SWPImageRead(uint32_t index, uintptr_t **addresses, size_t *addressCount) {
    SWPImage image = {0};
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(index);
    intptr_t slide = _dyld_get_image_vmaddr_slide(index);
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
        if (command->cmd == LC_SEGMENT_64 &&
            strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)command;
        command = (const void *)((const char *)command + command->cmdsize);
    }
    if (!symtab || !linkedit) return image;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    size_t capacity = sizeof(SWPSymbol) * (symtab->nsyms + 1);
    SWPSymbolTable *tables[] = {&image.roots, &image.accessors, &image.descriptors, &image.fieldOffsets,
                                &image.witnessTables, &image.metadata, &image.metadataSlots};
    for (size_t t = 0; t < sizeof tables / sizeof *tables; t++) tables[t]->symbols = malloc(capacity);
    if (addresses) *addresses = malloc(sizeof(uintptr_t) * (symtab->nsyms + 1));
    if (addressCount) *addressCount = 0;

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        const struct nlist_64 *symbol = &symbols[i];
        if ((symbol->n_type & N_STAB) || (symbol->n_type & N_TYPE) != N_SECT) continue;
        const char *name = strings + symbol->n_un.n_strx;
        uintptr_t address = symbol->n_value + slide;
        if (addresses) (*addresses)[(*addressCount)++] = address;
        if (strncmp(name, "_swapify.meta.", 14) == 0) append(&image.metadataSlots, name, address);
        if (strncmp(name, "_$s", 3) != 0) continue;
        if (hasSuffix(name, "TX")) append(&image.roots, name, address);
        else if (hasSuffix(name, "Ma") || hasSuffix(name, "vau") || hasSuffix(name, "Wl") ||
                 hasSuffix(name, "Wa"))
            append(&image.accessors, name, address);
        else if (hasSuffix(name, "Mn")) append(&image.descriptors, name, address);
        else if (hasSuffix(name, "Wvd")) append(&image.fieldOffsets, name, address);
        else if (hasSuffix(name, "WP")) append(&image.witnessTables, name, address);
        else if (hasSuffix(name, "VN") || hasSuffix(name, "CN") || hasSuffix(name, "ON"))
            append(&image.metadata, name, address);
    }
    for (size_t t = 0; t < sizeof tables / sizeof *tables; t++) sort(tables[t]);
    if (addresses) qsort(*addresses, *addressCount, sizeof(uintptr_t), compareAddresses);
    return image;
}

int SWPImageIndex(const char *path, uint32_t first) {
    char real[PATH_MAX], other[PATH_MAX];
    if (!realpath(path, real)) strlcpy(real, path, sizeof real);
    for (uint32_t i = first; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!realpath(name, other)) strlcpy(other, name, sizeof other);
        if (strcmp(real, other) == 0) return (int)i;
    }
    return -1;
}
