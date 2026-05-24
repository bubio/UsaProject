#ifndef USA_MOUSEMNG_H
#define USA_MOUSEMNG_H

#include <compiler.h>

enum {
	uPD8255A_LEFTBIT	= 0x80,
	uPD8255A_RIGHTBIT	= 0x20
};

#ifdef __cplusplus
extern "C" {
#endif

void mousemng_initialize(void);
void mousemng_callback(void);
UINT8 mousemng_getstat(SINT16 *x, SINT16 *y, int clear);

// Called from Zig input layer
void usa_mouse_move(int dx, int dy);
void usa_mouse_btn_down(int left);
void usa_mouse_btn_up(int left);

#ifdef __cplusplus
}
#endif

#endif
