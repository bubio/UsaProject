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

pub extern fn debug_print_offsets() void;
pub extern fn pccore_init_config() void;
pub extern fn np2_set_datadir(dir: [*:0]const u8) void;

pub extern var pc98_framebuffer: [640 * 480]u16;
