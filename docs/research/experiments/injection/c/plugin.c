#include <stdio.h>
int plugin_value(void) { return 42; }
__attribute__((constructor)) static void plugin_init(void) { fprintf(stderr, "[plugin] constructor ran\n"); }
