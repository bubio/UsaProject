#ifndef USA_SCRNMNG_H
#define USA_SCRNMNG_H

#include <embed/vramhdl.h>
#include <vram/scrndraw.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    RGB24_B = 2,
    RGB24_G = 1,
    RGB24_R = 0
};

typedef struct {
    UINT8   *ptr;
    int     xalign;
    int     yalign;
    int     width;
    int     height;
    UINT    bpp;
    int     extend;
} SCRNSURF;

typedef struct {
    BOOL    enable;
    int     width;
    int     height;
    int     bpp;
    int     flag;
    void*   pc98surf;
    void*   dispsurf;
    VRAMHDL vram;
} SCRNMNG;

typedef struct {
    int     width;
    int     height;
    int     bpp;
} SCRNMENU;

extern SCRNMNG scrnmng;
extern UINT16 pc98_framebuffer[640 * 480];

void scrnmng_getsize(int* pw, int* ph);
void scrnmng_setwidth(int posx, int width);
void scrnmng_setheight(int posy, int height);
const SCRNSURF *scrnmng_surflock(void);
void scrnmng_surfunlock(const SCRNSURF *surf);
RGB16 scrnmng_makepal16(RGB32 pal32);

#define scrnmng_isfullscreen() (0)
#define scrnmng_haveextend() (0)
#define scrnmng_getbpp() (16)
#define scrnmng_allflash()
#define scrnmng_palchanged()

BRESULT scrnmng_entermenu(SCRNMENU *smenu);
void scrnmng_leavemenu(void);

#ifdef __cplusplus
}
#endif

#endif
