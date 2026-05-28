#ifndef COMPILER_H
#define COMPILER_H

#include <stdio.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdbool.h>

#include "compiler_base.h"

#define msgbox(title, msg) printf("MSGBOX: %s: %s\n", title, msg)
#define __ASSERT(s)

#define RESOURCE_US
#define NP2_SIZE_VGA

#include <time.h>
static inline uint32_t _usa_gettick_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
#define GETTICK() _usa_gettick_ms()

#ifndef _snprintf
#define _snprintf snprintf
#endif

#include <common/milstr.h>

// Stubs for missing core symbols
extern const char* scsictr[];
#define TRACEOUT(s)
#define VERBOSE(s)

// Safe string comparison to avoid crash with NULL from file_getext
#ifdef milstr_cmp
#undef milstr_cmp
#endif
#define milstr_cmp(s, c) (((s) && (c)) ? milutf8_cmp(s, c) : ((s) == (c) ? 0 : 1))

// Definitions for INI/Profile (to satisfy wab.c and others)
typedef enum {
    INITYPE_STR,
    INITYPE_BOOL,
    INITYPE_SINT32,
    INITYPE_UINT32,
    INITYPE_HEX16,
    INITYPE_HEX32,
    INITYPE_USER
} INITYPE;

typedef struct {
    const char *item;
    INITYPE type;
    void *value;
    UINT32 arg;
} INITBL;

#endif
