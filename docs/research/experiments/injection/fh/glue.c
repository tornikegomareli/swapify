#include "fishhook.h"
#include <stdio.h>
int rebind_one(const char *name, void *replacement) {
  void *orig = NULL;
  struct rebinding r = { name, replacement, &orig };
  int rc = rebind_symbols(&r, 1);
  fprintf(stderr, "[glue] rebind_symbols(%s) rc=%d previous=%p\n", name, rc, orig);
  return rc;
}
