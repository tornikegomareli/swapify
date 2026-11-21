#include <stdio.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  fprintf(stderr, "[host] pid=%d HOME=%s\n", getpid(), getenv("HOME") ? getenv("HOME") : "(null)");
  fprintf(stderr, "[host] SIMULATOR_ROOT=%s\n", getenv("SIMULATOR_ROOT") ? getenv("SIMULATOR_ROOT") : "(null)");
  fprintf(stderr, "[host] DYLD_INSERT_LIBRARIES=%s\n", getenv("DYLD_INSERT_LIBRARIES") ? getenv("DYLD_INSERT_LIBRARIES") : "(null)");
  for (int i = 1; i < argc; i++) {
    void *h = dlopen(argv[i], RTLD_NOW);
    if (!h) { fprintf(stderr, "[host] dlopen(%s) FAILED: %s\n", argv[i], dlerror()); continue; }
    int (*f)(void) = (int (*)(void))dlsym(h, "plugin_value");
    fprintf(stderr, "[host] dlopen(%s) OK, plugin_value()=%d\n", argv[i], f ? f() : -1);
  }
  return 0;
}
