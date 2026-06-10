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
#include <vram/videofilter.h>
#include <vram/palettes.h>
#include <io/iocore.h>
#include <fdd/diskdrv.h>
#include <fdd/sxsi.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

// BOOL is int on Windows but bool elsewhere — wrap to expose a stable int ABI to Zig.
void usa_pccore_exec(int draw) { pccore_exec((BOOL)(draw != 0)); }

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
#include <soundmng.h>
#include <sound/sound.h>
#include <sound/opngen.h>
#include <sound/opngencfg.h>
#include <sound/psggen.h>
extern PSGGENCFG psggencfg;

extern void zig_audio_push(const int32_t* pcm, uint32_t count);
extern uint32_t zig_audio_writable(void);

// sndstream.samples — the chunk size NP2kai synthesizes per pcmlock/pcmunlock
// cycle. We also push exactly this many stereo frames to sokol_audio each
// soundmng_sync, matching the SDL backend's fixed-frame design.
static UINT g_sound_frame_samples = 0;

UINT soundmng_get_frame_samples(void) { return g_sound_frame_samples; }

UINT soundmng_create(UINT rate, UINT ms) {
    // Mirror the SDL backend: half of (rate*ms) rounded up to a power of two.
    // With rate=44100, ms=150 → 4096 stereo frames per chunk.
    if (ms < 20) ms = 20;
    else if (ms > 1000) ms = 1000;
    UINT samples = (rate * ms) / 1000 / 2;
    UINT pow2 = 32;
    while (pow2 < samples) pow2 <<= 1;
    g_sound_frame_samples = pow2;
    printf(">>> soundmng_create: rate=%u, ms=%u, samples=%u\n", rate, ms, pow2);
    return pow2;
}

void soundmng_destroy(void) {}
void soundmng_reset(void) {}
void soundmng_play(void) {}
void soundmng_stop(void) {}

// ---- Audio capture / autotest hooks (set via usa_audio_capture_*) ----
//
// usa_audio_capture_open opens a WAV file at the given path and writes a
// 44-byte placeholder header; subsequent soundmng_sync calls append the raw
// 16-bit stereo PCM. usa_audio_capture_close patches the data sizes in the
// header. The output is a plain RIFF/WAVE PCM file we can analyze offline.
//
// usa_audio_autotest toggles np2cfg.vol_fm / vol_ssg between 0 and 128 on a
// fixed timer driven from soundmng_sync (one toggle per ~1s of generated
// audio). Combined with capture, this lets us correlate vol_* with PCM
// amplitude without any UI interaction.
static FILE *g_cap_file = NULL;
static uint32_t g_cap_bytes = 0;
static int g_cap_autotest = 0;
static uint32_t g_cap_autotest_samples = 0;
static int g_cap_autotest_phase = 0;

static void wav_write_le16(FILE *f, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    fwrite(b, 1, 2, f);
}
static void wav_write_le32(FILE *f, uint32_t v) {
    uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    fwrite(b, 1, 4, f);
}

void usa_audio_capture_close(void);
static void capture_sig_handler(int sig) {
    (void)sig;
    usa_audio_capture_close();
    _exit(0);
}

int usa_audio_capture_open(const char *path, int autotest) {
    if (g_cap_file) return 0;
    FILE *f = fopen(path, "wb");
    if (!f) { printf(">>> audio capture: failed to open %s\n", path); return 0; }
    // Patch WAV header on SIGTERM/SIGINT so external scripts can stop us cleanly.
    signal(SIGINT,  capture_sig_handler);
    signal(SIGTERM, capture_sig_handler);
    // WAV header: RIFF + fmt(16) + data; sample rate fixed at 44100 Hz, 2ch, 16-bit
    fwrite("RIFF", 1, 4, f); wav_write_le32(f, 0);     // ChunkSize (patched at close)
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); wav_write_le32(f, 16);    // Subchunk1Size
    wav_write_le16(f, 1);                              // AudioFormat = PCM
    wav_write_le16(f, 2);                              // NumChannels = 2
    wav_write_le32(f, 44100);                          // SampleRate
    wav_write_le32(f, 44100 * 2 * 2);                  // ByteRate
    wav_write_le16(f, 4);                              // BlockAlign
    wav_write_le16(f, 16);                             // BitsPerSample
    fwrite("data", 1, 4, f); wav_write_le32(f, 0);     // Subchunk2Size (patched)
    g_cap_file = f;
    g_cap_bytes = 0;
    g_cap_autotest = autotest;
    g_cap_autotest_samples = 0;
    g_cap_autotest_phase = 0;
    printf(">>> audio capture: writing to %s%s\n", path, autotest ? " (autotest mode)" : "");
    return 1;
}

void usa_audio_capture_close(void) {
    if (!g_cap_file) return;
    uint32_t data_size = g_cap_bytes;
    uint32_t riff_size = 36 + data_size;
    fseek(g_cap_file, 4, SEEK_SET);  wav_write_le32(g_cap_file, riff_size);
    fseek(g_cap_file, 40, SEEK_SET); wav_write_le32(g_cap_file, data_size);
    fclose(g_cap_file);
    g_cap_file = NULL;
    printf(">>> audio capture: closed, %u PCM bytes written\n", data_size);
}

void soundmng_sync(void) {
    if (g_sound_frame_samples == 0) return;
    if (zig_audio_writable() < g_sound_frame_samples) return;

    const SINT32 *pcm = sound_pcmlock();
    if (!pcm) return;

    // Autotest: cycle vol_fm/vol_ssg every ~1s of audio (44100 frames).
    if (g_cap_autotest) {
        g_cap_autotest_samples += g_sound_frame_samples;
        if (g_cap_autotest_samples >= 44100) {
            g_cap_autotest_samples = 0;
            g_cap_autotest_phase = (g_cap_autotest_phase + 1) & 3;
            // 4 phases: (128,128) (0,128) (128,0) (0,0)
            np2cfg.vol_fm  = (g_cap_autotest_phase & 1) ? 0 : 128;
            np2cfg.vol_ssg = (g_cap_autotest_phase & 2) ? 0 : 128;
            extern void fmboard_updatevolume(void);
            fmboard_updatevolume();
            printf(">>> autotest phase=%d  vol_fm=%u vol_ssg=%u opncfg.fmvol=%d psg[15]=%d\n",
                g_cap_autotest_phase, np2cfg.vol_fm, np2cfg.vol_ssg, opncfg.fmvol, psggencfg.volume[15]);
            fflush(stdout);
        }
    }

    // Convert SINT32 stereo to 16-bit LE and append to the WAV.
    if (g_cap_file) {
        UINT n = g_sound_frame_samples * 2;  // stereo samples
        for (UINT i = 0; i < n; i++) {
            SINT32 v = pcm[i];
            if (v > 32767) v = 32767;
            else if (v < -32768) v = -32768;
            uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff) };
            fwrite(b, 1, 2, g_cap_file);
        }
        g_cap_bytes += n * 2;
    }

    zig_audio_push(pcm, g_sound_frame_samples);
    sound_pcmunlock(pcm);
}
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

// Drive access lamp: NP2kai's diskaccess paths call sysmng_fddaccess(drv)
// (which our src/sysmng.h routes here). We hold a small per-drive countdown
// that Zig decrements once per frame, so the lamp visibly blinks instead of
// flickering off between bursts of access.
#define USA_DRIVE_COUNT 4
#define USA_DRIVE_DECAY_FRAMES 6
static int g_fdd_access_decay[USA_DRIVE_COUNT] = {0};
static int g_hdd_access_decay[USA_DRIVE_COUNT] = {0};

void usa_fddaccess(UINT drv) {
    if (drv < USA_DRIVE_COUNT) g_fdd_access_decay[drv] = USA_DRIVE_DECAY_FRAMES;
}
void usa_hddaccess(UINT drv) {
    // sxsi passes the raw drive id, whose high bits flag SASI/IDE vs SCSI
    // (0x20). Mask to the drive index so SCSI access lights its lamp too.
    drv &= 0x0f;
    if (drv < USA_DRIVE_COUNT) g_hdd_access_decay[drv] = USA_DRIVE_DECAY_FRAMES;
}

int usa_fdd_lamp(unsigned int drv) {
    return (drv < USA_DRIVE_COUNT) && (g_fdd_access_decay[drv] > 0);
}
int usa_hdd_lamp(unsigned int drv) {
    return (drv < USA_DRIVE_COUNT) && (g_hdd_access_decay[drv] > 0);
}
void usa_lamp_tick(void) {
    for (int i = 0; i < USA_DRIVE_COUNT; i++) {
        if (g_fdd_access_decay[i] > 0) g_fdd_access_decay[i]--;
        if (g_hdd_access_decay[i] > 0) g_hdd_access_decay[i]--;
    }
}

double usa_cpu_clock_mhz(void) {
    return (double)pccore.realclock / 1000000.0;
}

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

// Mouse management
static SINT16 mouse_dx = 0;
static SINT16 mouse_dy = 0;
static UINT8  mouse_btn = uPD8255A_LEFTBIT | uPD8255A_RIGHTBIT;

void mousemng_initialize(void) {
	mouse_dx = 0;
	mouse_dy = 0;
	mouse_btn = uPD8255A_LEFTBIT | uPD8255A_RIGHTBIT;
}

void mousemng_callback(void) {}

UINT8 mousemng_getstat(SINT16 *x, SINT16 *y, int clear) {
	*x = mouse_dx;
	*y = mouse_dy;
	if (clear) {
		mouse_dx = 0;
		mouse_dy = 0;
	}
	return mouse_btn;
}

void usa_mouse_move(int dx, int dy) {
	mouse_dx += (SINT16)dx;
	mouse_dy += (SINT16)dy;
}

void usa_mouse_btn_down(int left) {
	if (left) {
		mouse_btn &= ~uPD8255A_LEFTBIT;
	} else {
		mouse_btn &= ~uPD8255A_RIGHTBIT;
	}
}

void usa_mouse_btn_up(int left) {
	if (left) {
		mouse_btn |= uPD8255A_LEFTBIT;
	} else {
		mouse_btn |= uPD8255A_RIGHTBIT;
	}
}

// Reset with HELP key held (for BIOS system setup menu)
void usa_pccore_reset(void); // defined below; re-applies the Sound Mixer after reset
void usa_reset_with_help(void) {
	usa_pccore_reset();
	keystat_keydown(0x3f);
}

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
    np2cfg.multiple = 4; // 10MHz
    np2cfg.samplingrate = 44100;
    np2cfg.delayms = 150;
    np2cfg.BEEP_VOL = 3;
    np2cfg.SOUND_SW = 0x06; // SOUNDID_PC_9801_86_26K
    np2cfg.usefmgen = 0;
    for (int i=0; i<6; i++) np2cfg.vol14[i] = 100;
    // Match np2kai's pccore_setdefault(): master 100, per-channel 64,
    // MIDI 128. Slider range in Sound Mixer is 0..128.
    np2cfg.vol_master = 100;
    np2cfg.vol_fm = 64;
    np2cfg.vol_ssg = 64;
    np2cfg.vol_adpcm = 64;
    np2cfg.vol_pcm = 64;
    np2cfg.vol_rhythm = 64;
    np2cfg.vol_midi = 128;
    np2cfg.DISPSYNC = 1;
    np2cfg.realpal = 32;
    np2cfg.skiplight = 64;
    np2cfg.grcg = 2;
    np2cfg.color16 = 1;
    np2cfg.BG_COLOR = 0x000000;
    np2cfg.FG_COLOR = 0xffffff;
    strcpy(np2cfg.model, "VX");
    np2cfg.usebios = 1;
    np2cfg.fddequip = 0x0f; // enable all 4 FDD slots

    // Sound board defaults — without these, OPNA gets attached to the wrong
    // I/O port and games can't detect the FM board, falling back to BEEP.
    //   snd86opt: bit0=1 → PC-9801-86 OPNA at port 0x188 (standard);
    //             bit4=1 → enable FM interrupt.
    //   snd26opt: bit4=1 → PC-9801-26K OPN at port 0x88 (standard).
    // snd86opt = bit0(=1 → I/O 0x188) | bits2-3(=0x0c → IRQ12 via the UI's
    // ints[2]={0,0x04,0x0c,0x08} table) | bit4(=1 → enable FM interrupt).
    // Without IRQ12 selected, opna_timer falls back to IRQ3 (s_irqtable[0])
    // and most FM-driven music engines stall or fall back to BEEP.
    np2cfg.snd86opt = 0x1f;  // bit1=1 → load sound BIOS ROM
    np2cfg.snd26opt = 0x10;

    // MSW4 bit 3 = sound board present (拡張ボード → サウンドボード → 使う)
    // Applied after msw_default in bios_itfcall via usa_apply_memsw_overrides().
    np2cfg.memsw[3] = 0x08;
}

void usa_apply_config_overrides(void) {
    np2cfg.SOUND_SW = 0x06;
    // snd86opt bit 1 = load sound BIOS ROM into 0xCC000. Without this the
    // BIOS sees MSW4 bit 3 (sound board present) but finds empty ROM space
    // at CC00:0000 and crashes BASIC after the boot banner.
    np2cfg.snd86opt = 0x1f;
    np2cfg.snd26opt = 0x10;
    np2cfg.memsw[3] |= 0x08;
    np2cfg.BEEP_VOL = 3;
    np2cfg.delayms = 150;
    np2cfg.multiple = 4;
    np2cfg.fddequip = 0x0f;
    // pccore_setdefault() ships with usefmgen=1, which routes OPNA audio
    // through fmgen (OPNA_Mix) instead of opngen_getpcm/psggen_getpcm. The
    // fmgen path uses its own per-instance volume state and does NOT respect
    // updates to opncfg.fmvol or psggencfg.volume[] — so live Sound Mixer
    // slider changes have no audible effect. Pin the legacy path on.
    np2cfg.usefmgen = 0;
}

// Load NP2kai's video filter with the documented HSV-smooth preset and set
// its initial on/off state. Always populates the profile so the filter can be
// toggled live from the Screen menu later; `initial_on` only decides whether
// it starts active.
//
// UsaProject does not read np2kai's .cfg (ini_read is stubbed), so the vf1_*
// fields stay zero unless we populate them here. The preset mirrors the NP2kai
// docs' example "vf1_p0_p0=1,6,15,5,30,30,90,0":
//   [0]=1  enable this filter (within the profile)
//   [1]=6  type = VFE_TYPE_HSVSMOOTH (THRU=0..ROTATEH=5, HSVSMOOTH=6)
//   [2]=15 radius R/10dot = 1.5dot (neighbouring dots)
//   [3]=5  sample N=5 → 5x5 window
//   [4]=30 dH (hue tolerance, 0..180)
//   [5]=30 dS (saturation tolerance, 0..128)
//   [6]=90 dV (value tolerance, 0..128)
//   [7]=0  weight type (0:none 1:linear 2:sign)
//
// pccore_init() reads these into hVFMng1, so this must run BEFORE it.
void usa_setup_video_filter(int initial_on) {
#if defined(SUPPORT_VIDEOFILTER)
    static const uint32_t hsv_preset[2 + 6] = {1, 6, 15, 5, 30, 30, 90, 0};
    np2cfg.vf1_enable = initial_on ? 1 : 0;
    np2cfg.vf1_bmponly = 0;       // also filter the live screen, not just bitmaps
    np2cfg.vf1_pcount = 1;        // one profile
    np2cfg.vf1_pno = 0;           // use profile 0
    np2cfg.vf1_profile[0][0] = 1; // profile 0: filter count = 1
    np2cfg.vf1_profile[0][1] = 0; // profile 0: output filter index = 0
    memcpy(np2cfg.vf1_param[0][0], hsv_preset, sizeof(hsv_preset));
#else
    (void)initial_on;
#endif
}

// Toggle the video filter live. scrndraw_draw() polls VideoFilter_GetEnable()
// every frame and forces a full-screen redraw when the flag flips, so this
// takes effect on the next frame.
void usa_set_video_filter(int on) {
#if defined(SUPPORT_VIDEOFILTER)
    np2cfg.vf1_enable = on ? 1 : 0;
    VideoFilter_SetEnable(hVFMng1, on ? TRUE : FALSE);
#else
    (void)on;
#endif
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

void np2_eject_fdd(unsigned drv) {
    fdd_eject((REG8)drv);
}

void np2_insert_hdd(unsigned drv, const char *path) {
    if (drv >= SASIHDD_MAX) return;
    // pccore_reset() calls diskdrv_hddbind() internally, which closes every
    // drive and reopens each one from np2cfg.sasihdd[]/idetype[]. Record the
    // image into the config here, BEFORE the reset, so the bind opens it and
    // the IDE BIOS boots from it. Calling sxsi_devopen() after the reset does
    // not work: diskdrv_hddbind() resets an unconfigured drive's devtype back
    // to SXSIDEV_NC, so the later open hits sxsi_devopen()'s default case and
    // fails — leaving the machine to fall through to N88-BASIC.
    file_cpyname(np2cfg.sasihdd[drv], path, MAX_PATH);
    np2cfg.idetype[drv] = SXSIDEV_HDD;
}

void np2_eject_hdd(unsigned drv) {
    if (drv >= SASIHDD_MAX) return;
    sxsi_devclose((REG8)drv);
    // Clear the recorded image so the next diskdrv_hddbind() (run by a reset)
    // does not re-attach it.
    np2cfg.sasihdd[drv][0] = '\0';
}

// --- UI setting accessors (called from Zig ui.zig) ---

#include <sound/beep.h>

uint8_t usa_get_nowait(void)       { return np2oscfg.NOWAIT; }
void    usa_set_nowait(uint8_t v)  { np2oscfg.NOWAIT = v; }

uint8_t usa_get_draw_skip(void)       { return np2oscfg.DRAW_SKIP; }
void    usa_set_draw_skip(uint8_t v)  { np2oscfg.DRAW_SKIP = v; }

uint8_t usa_get_keyboard(void)       { return np2oscfg.KEYBOARD; }
void    usa_set_keyboard(uint8_t v)  { np2oscfg.KEYBOARD = v; }

// CPU type: the core already maps a single index to all the cpu_family/model/
// stepping/feature fields via Get/SetCpuTypeIndex (pccore.c). 2 = i486SX.
unsigned usa_get_cpu_index(void)      { return (unsigned)GetCpuTypeIndex(); }
void     usa_set_cpu_index(unsigned v) { SetCpuTypeIndex((UINT)v); }

void usa_beep_setvol(unsigned vol) {
    np2cfg.BEEP_VOL = (UINT8)vol;
    beep_setvol(vol);
}

// np2kai already exposes fmboard_updatevolume(), which sets all chip volumes
// (FM/PSG/ADPCM/PCM/Rhythm/OPL + FMGEN variants) from np2cfg.vol_* and also
// calls adpcm_update / pcm86gen_update / rhythm_update so changes take effect
// on the next generated sample. Slider edits in the Zig UI write into
// np2cfg.vol_* but the chip generators latch their own scaled volumes; this
// glue wraps the existing core function so the dialog code stays in Zig.
void fmboard_updatevolume(void);
void usa_sound_apply_volumes(void) {
    fmboard_updatevolume();
}

// pccore_reset() resets every sound chip back to its power-on volume,
// dropping the FMGEN linear volumes / cs4231 scaling that the basic
// sound_init() path never establishes — so the Sound Mixer settings end up
// ignored after a reset (including the initial reset at startup). Wrap the
// core reset and re-apply the full np2cfg.vol_* mixer afterwards, matching
// the live slider-edit path. Done here in the glue layer so NP2kai's core
// stays unpatched. All reset call sites route through this wrapper.
void usa_pccore_reset(void) {
    pccore_reset();
    fmboard_updatevolume();
}

void usa_pal_makelcdpal(void) { pal_makelcdpal(); }
void usa_pal_makeskiptable(void) { pal_makeskiptable(); }
void usa_gdc_restorekacmode(void) { gdc_restorekacmode(); }
void usa_gdc_alldraw2(void) { gdcs.grphdisp |= GDCSCRN_ALLDRAW2; }

