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
pub const pccore_exec = c.pccore_exec;
pub const scrndraw_redraw = c.scrndraw_redraw;
pub const keystat_keydown = c.keystat_keydown;
pub const keystat_keyup = c.keystat_keyup;
pub const sound_sync = c.sound_sync;
pub const sound_pcmlock = c.sound_pcmlock;
pub const sound_pcmunlock = c.sound_pcmunlock;
pub const sound_get_active_samples = c.sound_get_active_samples;

// Glue layer (defined in src/np2_glue.c and src/np2_path.c)
pub extern fn pccore_init_config() void;
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

pub extern var pc98_framebuffer: [640 * 480]u16;
