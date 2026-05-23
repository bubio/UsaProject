#include <compiler.h>
#include "np2_path.h"
#include <scrnmng.h>
#include <soundmng.h>
#include <sysmng.h>
#include <taskmng.h>
#include <commng.h>
#include <dosio.h>
#include <timemng.h>
#include <joymng.h>
#include <kbdmng.h>
#include <mousemng.h>
#include <np2.h>
#include <fontmng.h>
#include <ini.h>
#include <stdarg.h>
#include <pccore.h>
#include <vram/scrndraw.h>
#include <fdd/diskdrv.h>
#include <fdd/sxsi.h>
#include <errno.h>

// Global structures expected by NP2kai
SCRNMNG scrnmng;
UINT sys_updates;
SYSMNGMISCINFO sys_miscinfo;
NP2OSCFG np2oscfg;

char hddfolder[MAX_PATH];
char fddfolder[MAX_PATH];
char bmpfilefolder[MAX_PATH];
UINT bmpfilenumber;
char modulefile[MAX_PATH];
char draw32bit;
UINT8 scrnmode;

// PC-98 Framebuffer
UINT16 pc98_framebuffer[640 * 480];
SCRNSURF pc98_surface;

// Screen management stubs
void scrnmng_getsize(int* pw, int* ph) { if (pw) *pw = 640; if (ph) *ph = 400; }
void scrnmng_setwidth(int posx, int width) { (void)posx; (void)width; }
void scrnmng_setheight(int posy, int height) { (void)posy; (void)height; }

const SCRNSURF *scrnmng_surflock(void) {
    pc98_surface.ptr = (UINT8*)pc98_framebuffer;
    pc98_surface.xalign = 2;
    pc98_surface.yalign = 640 * 2;
    pc98_surface.width = 640;
    pc98_surface.height = 400;
    pc98_surface.bpp = 16;
    pc98_surface.extend = 0;
    return &pc98_surface;
}

void scrnmng_surfunlock(const SCRNSURF *surf) { (void)surf; }

RGB16 scrnmng_makepal16(RGB32 pal32) {
    return (RGB16)(((pal32.p.r & 0xf8) << 8) | ((pal32.p.g & 0xfc) << 3) | (pal32.p.b >> 3));
}

void scrnmng_initialize(void) {
    memset(pc98_framebuffer, 0, sizeof(pc98_framebuffer));
    scrnmng.width = 640;
    scrnmng.height = 400;
    scrnmng.bpp = 16;
}

BRESULT scrnmng_create(UINT8 mode) { (void)mode; return SUCCESS; }
void scrnmng_destroy(void) {}
BRESULT scrnmng_entermenu(SCRNMENU *smenu) { (void)smenu; return FAILURE; }
void scrnmng_leavemenu(void) {}
void changescreen(UINT8 newmode) { (void)newmode; }
void scrnmng_blthdc(void) {}
void scrnmng_bltwab(void) {}
void scrnmng_update(void) {}
void scrnmng_updatefsres(void) {}

// Sound management stubs
UINT soundmng_create(UINT rate, UINT ms) { (void)ms; return rate ? rate : 44100; }
void soundmng_destroy(void) {}
void soundmng_reset(void) {}
void soundmng_play(void) {}
void soundmng_stop(void) {}
void soundmng_sync(void) {}
void soundmng_setreverse(BOOL reverse) { (void)reverse; }
BRESULT soundmng_pcmplay(UINT num, BOOL loop) { (void)num; (void)loop; return FAILURE; }
void soundmng_pcmstop(UINT num) { (void)num; }
BRESULT soundmng_initialize(void) { return SUCCESS; }
void soundmng_deinitialize(void) {}
int pcm_volume_default = 64;

// System management stubs
void sysmng_initialize(void) {}
void sysmng_deinitialize(void) {}
void sysmng_update(UINT update) { (void)update; }
void sysmng_cpureset(void) {}
void sysmng_updatecaption(UINT8 flag) { (void)flag; }

// Task management stubs
void taskmng_exit(void) {}
void taskmng_rolerelease(void) {}

// Communication management stubs — return a singleton no-op COMMNG so guest
// code that dereferences cm_rs232c->msg etc. doesn't crash.
static UINT  null_com_read(COMMNG self, UINT8 *data) { (void)self; (void)data; return 0; }
static UINT  null_com_write(COMMNG self, UINT8 data) { (void)self; (void)data; return 1; }
static UINT  null_com_writeretry(COMMNG self) { (void)self; return 1; }
static void  null_com_beginblock(COMMNG self) { (void)self; }
static void  null_com_endblock(COMMNG self) { (void)self; }
static UINT  null_com_lastwritesuccess(COMMNG self) { (void)self; return 1; }
static UINT8 null_com_getstat(COMMNG self) { (void)self; return 0; }
static INTPTR null_com_msg(COMMNG self, UINT msg, INTPTR param) { (void)self; (void)msg; (void)param; return 0; }
static void  null_com_release(COMMNG self) { (void)self; }

static _COMMNG null_commng = {
    COMCONNECT_OFF,
    null_com_read, null_com_write, null_com_writeretry,
    null_com_beginblock, null_com_endblock,
    null_com_lastwritesuccess, null_com_getstat,
    null_com_msg, null_com_release,
    0, 0, 0,
};

COMMNG commng_create(UINT device, BOOL onReset) { (void)device; (void)onReset; return &null_commng; }
void commng_destroy(COMMNG hdl) { (void)hdl; }
void commng_initialize(void) {}

// DOSIO stubs
void dosio_init(void) {}
void dosio_term(void) {}
FILEH file_open(const OEMCHAR *path) {
    if (!path || !path[0]) return NULL;
    FILEH h = fopen(path, "rb+");
    if (!h) printf("file_open failed: %s (errno: %d)\n", path, errno);
#ifdef DEBUG_DOSIO
    else printf("file_open: %s -> %p\n", path, h);
#endif
    return h;
}
FILEH file_open_rb(const OEMCHAR *path) {
    if (!path || !path[0]) return NULL;
    FILEH h = fopen(path, "rb");
    if (!h) printf("file_open_rb failed: %s (errno: %d)\n", path, errno);
#ifdef DEBUG_DOSIO
    else printf("file_open_rb: %s -> %p\n", path, h);
#endif
    return h;
}
FILEH file_create(const OEMCHAR *path) {
    if (!path || !path[0]) return NULL;
    FILEH h = fopen(path, "wb+");
    if (!h) printf("file_create failed: %s (errno: %d)\n", path, errno);
    return h;
}
FILEPOS file_seek(FILEH handle, FILEPOS pointer, int method) { if (!handle) return 0; fseek(handle, pointer, method); return ftell(handle); }
UINT file_read(FILEH handle, void *data, UINT length) { if (!handle) return 0; return fread(data, 1, length, handle); }
UINT file_write(FILEH handle, const void *data, UINT length) { if (!handle) return 0; return fwrite(data, 1, length, handle); }
short file_close(FILEH handle) { if (handle) fclose(handle); return 0; }
FILELEN file_getsize(FILEH handle) { if (!handle) return 0; long pos = ftell(handle); fseek(handle, 0, SEEK_END); long size = ftell(handle); fseek(handle, pos, SEEK_SET); return size; }
short file_delete(const OEMCHAR *path) { if (!path || !path[0]) return FAILURE; return remove(path); }
short file_attr(const OEMCHAR *path) { (void)path; return 0; }
// Path / cwd helpers (file_getcd, file_catname, file_setcd, file_cutname,
// file_getext, file_getname, np2_set_datadir) are defined in np2_path.c.
// _c variants resolve the name relative to the current data directory
// (curpath in np2_path.c) — matches SDL backend semantics.
FILEH file_open_c(const OEMCHAR *path) { return file_open(file_getcd(path)); }
FILEH file_open_rb_c(const OEMCHAR *path) { return file_open_rb(file_getcd(path)); }
FILEH file_create_c(const OEMCHAR *path) { return file_create(file_getcd(path)); }
short file_delete_c(const OEMCHAR *path) { return file_delete(file_getcd(path)); }
short file_attr_c(const OEMCHAR *path) { return file_attr(file_getcd(path)); }
void file_cutext(OEMCHAR *path) { (void)path; }
void file_cutseparator(OEMCHAR *path) { (void)path; }
void file_setseparator(OEMCHAR *path, int maxlen) { (void)path; (void)maxlen; }
FLISTH file_list1st(const OEMCHAR *dir, FLINFO *fli) { (void)dir; (void)fli; return NULL; }
BRESULT file_listnext(FLISTH hdl, FLINFO *fli) { (void)hdl; (void)fli; return FAILURE; }
void file_listclose(FLISTH hdl) { (void)hdl; }
short file_getdatetime(FILEH handle, DOSDATE *dosdate, DOSTIME *dostime) { (void)handle; (void)dosdate; (void)dostime; return FAILURE; }
short file_rename(const OEMCHAR *existpath, const OEMCHAR *newpath) { (void)existpath; (void)newpath; return FAILURE; }
short file_dircreate(const OEMCHAR *path) { (void)path; return FAILURE; }
short file_dirdelete(const OEMCHAR *path) { (void)path; return FAILURE; }

// Time management stubs
BRESULT timemng_gettime(_SYSTIME *systime) { (void)systime; return FAILURE; }

// Joy management stubs
void joymng_initialize(void) {}
void joymng_deinitialize(void) {}
UINT8 joymng_getstat(void) { return 0xff; }
BOOL joymng_available(void) { return FALSE; }

// Kbd management stubs
void kbdmng_initialize(void) {}
void kbdmng_callback(void) {}
void kbdmng_keydown(UINT8 key) { (void)key; }
void kbdmng_keyup(UINT8 key) { (void)key; }
void kbdmng_reset(void) {}

// Mouse management stubs
void mousemng_initialize(void) {}
void mousemng_callback(void) {}
BOOL mousemng_getstat(SINT16 *x, SINT16 *y, UINT8 *btn) { (void)x; (void)y; (void)btn; return FALSE; }

// Font management stubs
void fontmng_initialize(void) {}
void fontmng_deinitialize(void) {}
FNTDAT fontmng_get(void* hdl, const OEMCHAR* str) { (void)hdl; (void)str; return NULL; }
void* fontmng_create(int size, UINT type, const char *fontface) { (void)size; (void)type; (void)fontface; return NULL; }
void fontmng_destroy(void *hdl) { (void)hdl; }

// Ini management stubs
void ini_read(const OEMCHAR *path, const OEMCHAR *title, const INITBL *tbl, UINT count) { (void)path; (void)title; (void)tbl; (void)count; }
void ini_write(const OEMCHAR *path, const OEMCHAR *title, const INITBL *tbl, UINT count) { (void)path; (void)title; (void)tbl; (void)count; }
void initgetfile(OEMCHAR *path, int maxlen) { (void)path; (void)maxlen; }

// SCSI stubs
const char* scsictr[16] = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F" };

// Misc stubs
void bios_lio(void) {}
void lio_initialize(void) {}
void midimod_create(void) {}
void midimod_destroy(void) {}
void midimod_loadall(void) {}
void midiout_create(void) {}
void midiout_destroy(void) {}
void midiout_get(void) {}
void midiout_longmsg(void) {}
void midiout_shortmsg(void) {}

// DUMMY GLOBALS for bios.c when SUPPORT_WAB/VGA is disabled
struct {
    UINT8 relaystateint;
    UINT8 relaystateext;
    int wndWidth;
    int wndHeight;
} np2wab;

struct {
    UINT8 modex;
    UINT32 VRAMWindowAddr3;
} np2clvga;

void np2wab_setRelayState(UINT8 state) { (void)state; }
void np2wab_setScreenSize(int width, int height) { (void)width; (void)height; }
void pc98_cirrus_vga_resetresolution(void) {}
void wabrly_initialize(void) {}

// Debugging
#include <stddef.h>
void debug_print_offsets(void) {
    printf("--- C-land Struct Offsets ---\n");
    printf("sizeof(NP2CFG): %zu\n", sizeof(NP2CFG));
    printf("offset of vol14: %zu\n", offsetof(NP2CFG, vol14));
    printf("offset of samplingrate: %zu\n", offsetof(NP2CFG, samplingrate));
    printf("offset of model: %zu\n", offsetof(NP2CFG, model));
    printf("-----------------------------\n");
}

void pccore_init_config(void) {
    memset(&np2cfg, 0, sizeof(np2cfg));
    np2cfg.baseclock = 2457600;
    np2cfg.multiple = 20;
    np2cfg.samplingrate = 44100;
    np2cfg.delayms = 150;
    np2cfg.BEEP_VOL = 3;
    for (int i=0; i<6; i++) np2cfg.vol14[i] = 64;
    np2cfg.vol_master = 64;
    np2cfg.vol_fm = 64;
    np2cfg.vol_ssg = 64;
    np2cfg.vol_adpcm = 64;
    np2cfg.vol_pcm = 64;
    np2cfg.vol_rhythm = 64;
    np2cfg.vol_midi = 64;
    strcpy(np2cfg.model, "VX");
    np2cfg.fddequip = 0x0f; // enable all 4 FDD slots
}

void np2_set_model(const char *name) {
    if (!name || !name[0]) return;
    // np2cfg.model is OEMCHAR[8]; truncate-safe copy with NUL.
    size_t n = strlen(name);
    if (n >= sizeof(np2cfg.model)) n = sizeof(np2cfg.model) - 1;
    memcpy(np2cfg.model, name, n);
    np2cfg.model[n] = '\0';
}

void np2_insert_fdd(unsigned drv, const char *path) {
    // readyfdd inserts immediately (setfdd would wait 20 frames via the
    // diskdrv delay queue, which the BIOS sometimes gives up on).
    diskdrv_readyfdd((REG8)drv, path, 0);
}

void np2_insert_hdd(unsigned drv, const char *path) {
    sxsi_devopen((REG8)drv, path);
}
