#include <stdio.h>
#include <dlfcn.h>
#include <unistd.h>
int main(void) {
  fprintf(stderr, "[waiter] pid=%d\n", getpid());
  for (int i = 0; i < 40; i++) {
    int (*f)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "plugin_value");
    if (f) { fprintf(stderr, "[waiter] plugin_value() visible after %ds = %d\n", i, f()); return 0; }
    sleep(1);
  }
  fprintf(stderr, "[waiter] plugin never loaded\n"); return 1;
}
