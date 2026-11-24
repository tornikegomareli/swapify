// Code caves in the app's signed __TEXT segment. Each starts on a 16 KB page.
// spike_cave:  64 KB (4 pages) of `brk #1`. LLDB writes code into it (test 2).
// spike_cave2: 16 KB (1 page) of `brk #2`. The app tries vm_protect VM_PROT_COPY on it (test 1c).

    .section __TEXT,__text,regular,pure_instructions
    .p2align 14
    .globl _spike_cave
_spike_cave:
    .rept 16384
    brk #0x1
    .endr

    .p2align 14
    .globl _spike_cave2
_spike_cave2:
    .rept 4096
    brk #0x2
    .endr

    .p2align 14
    .globl _spike_cave_end
_spike_cave_end:
    ret
