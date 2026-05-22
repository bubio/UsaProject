pub const c = @cImport({
    @cInclude("compiler.h");
    @cInclude("pccore.h");
    @cInclude("dosio.h");
    @cInclude("scrnmng.h");
    @cInclude("soundmng.h");
    @cInclude("sysmng.h");
    @cInclude("taskmng.h");
    @cInclude("vram/scrndraw.h");
});

// NP2kai core entry points (re-exported through c.zig so callers don't
// need to mix cz.foo and c.bar).
pub const pccore_init = c.pccore_init;
pub const pccore_term = c.pccore_term;
pub const pccore_reset = c.pccore_reset;
pub const pccore_exec = c.pccore_exec;
pub const scrndraw_redraw = c.scrndraw_redraw;

// Glue layer (defined in src/np2_glue.c and src/np2_path.c)
pub extern fn pccore_init_config() void;
pub extern fn np2_set_datadir(dir: [*:0]const u8) void;
pub extern fn debug_print_offsets() void;

pub extern var pc98_framebuffer: [640 * 480]u16;
