#ifndef USA_MOUSEMNG_H
#define USA_MOUSEMNG_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

void mousemng_initialize(void);
void mousemng_callback(void);
BOOL mousemng_getstat(SINT16 *x, SINT16 *y, UINT8 *btn);

#ifdef __cplusplus
}
#endif

#endif
