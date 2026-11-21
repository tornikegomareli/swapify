#import "Agent.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>

// Simulator processes are ad-hoc signed and not hardened, so a private copy of
// a code page (VM_PROT_COPY) can be written and made executable again.

BOOL SWPWriteJump(uintptr_t at, uintptr_t to) {
    uint32_t code[4] = {0x58000050, 0xd61f0200, 0, 0};  // ldr x16, #8; br x16; .quad to
    memcpy(&code[2], &to, sizeof to);
    vm_address_t page = at & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t length = at + sizeof code - page;
    if (vm_protect(mach_task_self(), page, length, FALSE,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return NO;
    memcpy((void *)at, code, sizeof code);
    vm_protect(mach_task_self(), page, length, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void *)at, sizeof code);
    return YES;
}

void SWPWriteWord(uintptr_t at, uint64_t value) {
    if (*(const uint64_t *)at == value) return;
    vm_address_t page = at & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t length = at + sizeof value - page;
    vm_protect(mach_task_self(), page, length, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    memcpy((void *)at, &value, sizeof value);
}
