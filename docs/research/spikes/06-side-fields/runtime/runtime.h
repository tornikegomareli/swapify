#include <stdbool.h>
bool swp_repoint(const char *patchSuffix, const char *root);
int swp_side_boxes_alive(void);
void *SWPSideField(void *object, const char *key, const char *typeName, const void *context, bool initializing, bool *fresh);
bool swp_copy_word(const char *patchSuffix, const char *name);
long swp_word(const char *suffix, const char *name);
