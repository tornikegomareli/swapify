#include <stdio.h>
__attribute__((constructor)) static void insert_init(void) { fprintf(stderr, "[insert] DYLD_INSERT_LIBRARIES dylib constructor ran\n"); }
