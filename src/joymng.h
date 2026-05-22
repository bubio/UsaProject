#ifndef USA_JOYMNG_H
#define USA_JOYMNG_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

void joymng_initialize(void);
void joymng_deinitialize(void);
UINT8 joymng_getstat(void);

#ifdef __cplusplus
}
#endif

#endif
