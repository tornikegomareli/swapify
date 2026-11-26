#import "Agent.h"

// New code runs on objects with the old layout, so a patch must not change
// stored properties or a class vtable. Offsets follow swift/ABI/Metadata.h:
// TargetClassDescriptor, TargetStructDescriptor, TargetEnumDescriptor and
// reflection FieldDescriptor.

enum { KindClass = 16, KindStruct = 17, KindEnum = 18 };

static const uint8_t *relative(const void *field) {
    int32_t offset;
    memcpy(&offset, field, sizeof offset);
    return offset ? (const uint8_t *)field + offset : NULL;
}

static const char *descriptorName(const uint8_t *descriptor) {
    const uint8_t *name = descriptor ? relative(descriptor + 8) : NULL;
    return name ? (const char *)name : "";
}

// Compares two mangled type names. Symbolic references point into different
// images, so they compare by the referenced descriptor's name. Direct (0x01)
// and indirect (0x02) references to the same type are equal: the linker picks
// one or the other.
static BOOL sameMangledName(const uint8_t *a, const uint8_t *b) {
    while (*a && *b) {
        BOOL aContext = *a == 0x01 || *a == 0x02, bContext = *b == 0x01 || *b == 0x02;
        if (aContext && bContext) {
            const uint8_t *aTarget = relative(a + 1), *bTarget = relative(b + 1);
            if (*a == 0x02) aTarget = *(const uint8_t *const *)aTarget;
            if (*b == 0x02) bTarget = *(const uint8_t *const *)bTarget;
            if (strcmp(descriptorName(aTarget), descriptorName(bTarget)) != 0) return NO;
            a += 5, b += 5;
            continue;
        }
        if (*a != *b) return NO;
        if (*a <= 0x17) a += 5, b += 5;       // other 4-byte relative references
        else if (*a <= 0x1F) a += 9, b += 9;  // pointer-sized absolute references
        else a++, b++;
    }
    return *a == *b;
}

const char *SWPLayoutDifference(const uint8_t *old, const uint8_t *new) {
    static char reason[160];
    uint32_t kind = *(const uint32_t *)old & 0x1F;
    if (kind != (*(const uint32_t *)new & 0x1F)) return "kind of type changed";
    if (kind == KindClass) {
        // Offset 32 is NumImmediateMembers (vtable entries). The other words are
        // metadata bounds, field count and the field offset vector offset.
        if (*(const uint32_t *)(old + 32) != *(const uint32_t *)(new + 32))
            return "methods added or removed";
        if (memcmp(old + 24, new + 24, 20) != 0) return "stored properties changed";
        // Offset 20: the superclass's mangled name. Objects of the old superclass keep its layout.
        const uint8_t *oldSuper = relative(old + 20), *newSuper = relative(new + 20);
        if ((oldSuper == NULL) != (newSuper == NULL) || (oldSuper && !sameMangledName(oldSuper, newSuper)))
            return "superclass changed";
    } else if (kind == KindStruct || kind == KindEnum) {
        if (memcmp(old + 20, new + 20, 8) != 0)
            return kind == KindEnum ? "cases changed" : "stored properties changed";
    } else {
        return NULL;
    }

    const uint8_t *oldFields = relative(old + 16), *newFields = relative(new + 16);
    if (!oldFields || !newFields) return oldFields == newFields ? NULL : "stored properties changed";
    uint32_t count = *(const uint32_t *)(oldFields + 12);
    if (count != *(const uint32_t *)(newFields + 12)) return "stored properties changed";
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *a = oldFields + 16 + 12 * i, *b = newFields + 16 + 12 * i;
        const uint8_t *aName = relative(a + 8), *bName = relative(b + 8);
        const char *name = aName ? (const char *)aName : "?";
        if (strcmp(name, bName ? (const char *)bName : "") != 0) {
            snprintf(reason, sizeof reason, "property '%s' renamed or moved", name);
            return reason;
        }
        if (*(const uint32_t *)a != *(const uint32_t *)b) {
            snprintf(reason, sizeof reason, "property '%s' changed between let and var", name);
            return reason;
        }
        const uint8_t *aType = relative(a + 4), *bType = relative(b + 4);
        if ((aType == NULL) != (bType == NULL) || (aType && !sameMangledName(aType, bType))) {
            snprintf(reason, sizeof reason, "property '%s' changed type", name);
            return reason;
        }
    }
    return NULL;
}
