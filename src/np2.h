#ifndef USA_NP2_H
#define USA_NP2_H

#include <compiler.h>
#include <commng.h>

typedef struct {
    UINT8   direct;
    UINT8   port;
    UINT8   def_en;
    UINT8   param;
    UINT32  speed;
    char    mout[MAX_PATH];
    char    min[MAX_PATH];
    char    mdl[64];
    char    def[MAX_PATH];
} COMCFG;

typedef struct {
    UINT8   NOWAIT;
    UINT8   DRAW_SKIP;
    UINT8   KEYBOARD;
    UINT8   resume;
    UINT8   jastsnd;
    UINT8   I286SAVE;
    UINT8   xrollkey;
    UINT8   snddrv;
    char    MIDIDEV[2][MAX_PATH];
    UINT32  MIDIWAIT;
    COMCFG  mpu;
    UINT8   readonly;
} NP2OSCFG;

extern NP2OSCFG np2oscfg;

extern char hddfolder[MAX_PATH];
extern char fddfolder[MAX_PATH];
extern char bmpfilefolder[MAX_PATH];
extern UINT bmpfilenumber;
extern char modulefile[MAX_PATH];
extern char draw32bit;
extern UINT8 scrnmode;

void changescreen(UINT8 newmode);

#endif
