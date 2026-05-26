const sokol = @import("sokol");
const sapp = sokol.app;

pub const c = @cImport({
    @cInclude("sokol_gfx.h");
    @cInclude("sokol_app.h");
    @cDefine("NK_INCLUDE_FIXED_TYPES", "");
    @cDefine("NK_INCLUDE_STANDARD_IO", "");
    @cDefine("NK_INCLUDE_DEFAULT_ALLOCATOR", "");
    @cDefine("NK_INCLUDE_VERTEX_BUFFER_OUTPUT", "");
    @cDefine("NK_INCLUDE_FONT_BAKING", "");
    @cDefine("NK_INCLUDE_DEFAULT_FONT", "");
    @cDefine("NK_INCLUDE_STANDARD_VARARGS", "");
    @cDefine("NK_BUTTON_TRIGGER_ON_RELEASE", "");
    @cInclude("nuklear.h");
    @cInclude("sokol_nuklear.h");
});

pub fn setup(desc: c.snk_desc_t) void {
    c.snk_setup(&desc);
}

pub fn newFrame() *c.nk_context {
    return c.snk_new_frame();
}

pub fn render(width: c_int, height: c_int) void {
    c.snk_render(width, height);
}

pub fn handleEvent(ev: *const sapp.Event) bool {
    return c.snk_handle_event(@ptrCast(ev));
}

pub fn shutdown() void {
    c.snk_shutdown();
}
