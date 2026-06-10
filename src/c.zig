pub const c = @cImport({
    @cInclude("compiler.h");
    @cInclude("pccore.h");
    @cInclude("dosio.h");
    @cInclude("scrnmng.h");
    @cInclude("soundmng.h");
    @cInclude("sysmng.h");
    @cInclude("taskmng.h");
    @cInclude("keystat.h");
    @cInclude("vram/scrndraw.h");
    @cInclude("sound/sound.h");
});

// NP2kai core entry points (re-exported through c.zig so callers don't
// need to mix cz.foo and c.bar).
pub const pccore_init = c.pccore_init;
pub const pccore_term = c.pccore_term;
pub const pccore_reset = c.pccore_reset;
pub extern fn usa_pccore_exec(draw: c_int) void;
pub inline fn pccore_exec(draw: bool) void {
    usa_pccore_exec(if (draw) 1 else 0);
}
pub const scrndraw_redraw = c.scrndraw_redraw;
pub const keystat_keydown = c.keystat_keydown;
pub const keystat_keyup = c.keystat_keyup;
pub const sound_sync = c.sound_sync;
pub const sound_pcmlock = c.sound_pcmlock;
pub const sound_pcmunlock = c.sound_pcmunlock;
pub const sound_get_active_samples = c.sound_get_active_samples;

// Glue layer (defined in src/np2_glue.c and src/np2_path.c)
pub extern fn pccore_init_config() void;
pub extern fn usa_apply_config_overrides() void;
pub extern fn usa_setup_video_filter(initial_on: c_int) void;
pub extern fn usa_set_video_filter(on: c_int) void;
pub extern fn np2_set_datadir(dir: [*:0]const u8) void;
pub extern fn np2_set_model(name: [*:0]const u8) void;
pub extern fn np2_insert_fdd(drv: c_uint, path: [*:0]const u8) void;
pub extern fn np2_eject_fdd(drv: c_uint) void;
pub extern fn np2_insert_hdd(drv: c_uint, path: [*:0]const u8) void;
pub extern fn np2_eject_hdd(drv: c_uint) void;
pub extern fn debug_print_offsets() void;

// UI helpers (defined in src/np2_glue.c)
pub extern fn usa_fdd_lamp(drv: c_uint) c_int;
pub extern fn usa_hdd_lamp(drv: c_uint) c_int;
pub extern fn usa_lamp_tick() void;
pub extern fn usa_cpu_clock_mhz() f64;

pub extern fn usa_reset_with_help() void;

pub extern var pc98_framebuffer: [640 * 480]u16;

// Mouse (defined in src/np2_glue.c)
pub extern fn usa_mouse_move(dx: c_int, dy: c_int) void;
pub extern fn usa_mouse_btn_down(left: c_int) void;
pub extern fn usa_mouse_btn_up(left: c_int) void;

// UI setting accessors (defined in src/np2_glue.c)
pub extern fn usa_get_nowait() u8;
pub extern fn usa_set_nowait(v: u8) void;
pub extern fn usa_get_draw_skip() u8;
pub extern fn usa_set_draw_skip(v: u8) void;
pub extern fn usa_get_keyboard() u8;
pub extern fn usa_set_keyboard(v: u8) void;
pub extern fn usa_get_cpu_index() c_uint;
pub extern fn usa_set_cpu_index(v: c_uint) void;
pub extern fn usa_beep_setvol(vol: c_uint) void;
pub extern fn usa_sound_apply_volumes() void;
pub extern fn usa_audio_capture_open(path: [*:0]const u8, autotest: c_int) c_int;
pub extern fn usa_audio_capture_close() void;
pub extern fn usa_pal_makelcdpal() void;
pub extern fn usa_pal_makeskiptable() void;
pub extern fn usa_gdc_restorekacmode() void;
pub extern fn usa_gdc_alldraw2() void;

// State save / load (NP2kai statsave.c). OEMCHAR is UTF-8 char under OSLANG_UTF8,
// so paths pass through as plain [*:0]u8 with no conversion. This build defines
// __LIBRETRO__, so the *_d entry points take the path as an argument rather than
// the g_u8ControlState/m_strStateFilename queue the SDL/X11 frontends use. The UI
// captures the chosen path and calls *_d directly at a frame boundary (see
// ui.flushPendingState, driven from main.zig's frame loop).
pub extern fn statsave_check(filename: [*:0]const u8, buf: [*]u8, size: c_int) c_int;
pub extern fn statsave_save_d(filename: [*:0]const u8) c_int;
pub extern fn statsave_load_d(filename: [*:0]const u8) c_int;

// Disk paths currently mounted in the core, used to resync the UI's drive slots
// after a state load. Return a pointer into a static buffer ("" when the drive
// is empty, NULL only for an out-of-range drive index).
pub extern fn fdd_diskname(drv: u8) [*c]u8;
pub extern fn sxsi_getfilename(drv: u8) [*c]u8;

pub const STATFLAG_SUCCESS: c_int = 0;
pub const STATFLAG_DISKCHG: c_int = 0x0001;
pub const STATFLAG_VERCHG: c_int = 0x0002;
pub const STATFLAG_WARNING: c_int = 0x0080;
pub const STATFLAG_VERSION: c_int = 0x0100;
pub const STATFLAG_FAILURE: c_int = -1;
