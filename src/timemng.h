#ifndef USA_TIMEMNG_H
#define USA_TIMEMNG_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    UINT16  year;
    UINT8   month;
    UINT8   week;
    UINT8   day;
    UINT8   hour;
    UINT8   minute;
    UINT8   second;
    UINT16  milli;
} _SYSTIME;

BRESULT timemng_gettime(_SYSTIME *systime);

#ifdef __cplusplus
}
#endif

#endif
