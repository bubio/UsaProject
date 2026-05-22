#ifndef USA_FONTMNG_H
#define USA_FONTMNG_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    FDAT_DEPTH      = 255,
    FDAT_DEPTHBIT   = 8
};

typedef struct {
    int width;
    int height;
    int pitch;
} _FNTDAT, *FNTDAT;

void fontmng_initialize(void);
void fontmng_deinitialize(void);
FNTDAT fontmng_get(void* hdl, const OEMCHAR* str);

#ifdef __cplusplus
}
#endif

#endif
