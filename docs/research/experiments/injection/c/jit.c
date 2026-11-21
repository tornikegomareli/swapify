#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <pthread.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
static const unsigned int code[] = { 0x52800540 /* mov w0,#42 */, 0xd65f03c0 /* ret */ };
typedef int (*fn_t)(void);
int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "probe";
  void (*wp)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
  int (*wps)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_supported_np");
  fprintf(stderr, "[jit] dlsym pthread_jit_write_protect_np=%p supported_np=%p -> %d\n", (void*)wp, (void*)wps, wps ? wps() : -1);
  if (!strcmp(mode, "mapjit")) {
    void *p = mmap(NULL, 16384, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON|MAP_JIT, -1, 0);
    fprintf(stderr, "[jit] MAP_JIT mmap -> %p errno=%d\n", p, p == MAP_FAILED ? errno : 0);
    if (p == MAP_FAILED) return 1;
    if (wp) wp(0);
    memcpy(p, code, sizeof code);
    if (wp) wp(1);
    sys_icache_invalidate(p, sizeof code);
    fprintf(stderr, "[jit] MAP_JIT call -> %d\n", ((fn_t)p)());
  } else if (!strcmp(mode, "mprotect")) {
    void *q = mmap(NULL, 16384, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    memcpy(q, code, sizeof code);
    int r = mprotect(q, 16384, PROT_READ|PROT_EXEC);
    fprintf(stderr, "[jit] mprotect RX -> %d errno=%d\n", r, r ? errno : 0);
    sys_icache_invalidate(q, sizeof code);
    fprintf(stderr, "[jit] calling RX page from anonymous memory...\n");
    fprintf(stderr, "[jit] mprotect call -> %d\n", ((fn_t)q)());
  } else if (!strcmp(mode, "remap")) {
    vm_address_t rw = 0, rx = 0; vm_prot_t cur, max;
    kern_return_t kr = vm_allocate(mach_task_self(), &rw, 16384, VM_FLAGS_ANYWHERE);
    memcpy((void*)rw, code, sizeof code);
    kr = vm_remap(mach_task_self(), &rx, 16384, 0, VM_FLAGS_ANYWHERE, mach_task_self(), rw, FALSE, &cur, &max, VM_INHERIT_NONE);
    fprintf(stderr, "[jit] vm_remap kr=%d cur=%d max=%d\n", kr, cur, max);
    kr = vm_protect(mach_task_self(), rx, 16384, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
    fprintf(stderr, "[jit] vm_protect RX kr=%d\n", kr);
    sys_icache_invalidate((void*)rx, sizeof code);
    fprintf(stderr, "[jit] remap call -> %d\n", ((fn_t)rx)());
  }
  return 0;
}
