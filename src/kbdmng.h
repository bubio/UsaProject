#ifndef USA_KBDMNG_H
#define USA_KBDMNG_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

void kbdmng_initialize(void);
void kbdmng_callback(void);
void kbdmng_keydown(UINT8 key);
void kbdmng_keyup(UINT8 key);
void kbdmng_reset(void);

#ifdef __cplusplus
}
#endif

#endif
