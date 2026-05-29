const std = @import("std");
const sapp = @import("sokol").app;

pub const shader_vs_source = @embedFile("shaders/blit.vs.glsl");
pub const shader_fs_source = @embedFile("shaders/blit.fs.glsl");
pub const shader_entry = "main";

pub const data_dir_template = "{s}/.local/share/{s}";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("HOME");
}

pub fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// --- Native window control via Xlib ---

const XSizeHints = extern struct {
    flags: c_long = 0,
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
    min_width: c_int = 0,
    min_height: c_int = 0,
    max_width: c_int = 0,
    max_height: c_int = 0,
    width_inc: c_int = 0,
    height_inc: c_int = 0,
    min_aspect_x: c_int = 0,
    min_aspect_y: c_int = 0,
    max_aspect_x: c_int = 0,
    max_aspect_y: c_int = 0,
    base_width: c_int = 0,
    base_height: c_int = 0,
    win_gravity: c_int = 0,
};

const PMinSize: c_long = 1 << 4;
const PResizeInc: c_long = 1 << 6;
const PBaseSize: c_long = 1 << 8;

extern "c" fn XResizeWindow(display: ?*const anyopaque, w: c_ulong, width: c_uint, height: c_uint) c_int;
extern "c" fn XSetWMNormalHints(display: ?*const anyopaque, w: c_ulong, hints: *XSizeHints) void;
extern "c" fn XFlush(display: ?*const anyopaque) c_int;

fn x11Window() ?struct { dpy: *const anyopaque, win: c_ulong } {
    const dpy = sapp.x11GetDisplay() orelse return null;
    const win_ptr = sapp.x11GetWindow() orelse return null;
    return .{ .dpy = dpy, .win = @intCast(@intFromPtr(win_ptr)) };
}

/// Resize the window's content area (in pixels).
pub fn setWindowSize(w: u32, h: u32) void {
    if (sapp.isFullscreen()) return;
    const x = x11Window() orelse return;
    _ = XResizeWindow(x.dpy, x.win, w, h);
    _ = XFlush(x.dpy);
}

/// Constrain interactive resizing to integer multiples of the screen via the
/// WM size hints: width = fb_w*N, height = chrome_h + fb_h*N.
pub fn lockWindow(fb_w: u32, fb_h: u32, chrome_h: u32) void {
    const x = x11Window() orelse return;
    var hints = XSizeHints{};
    hints.flags = PMinSize | PResizeInc | PBaseSize;
    hints.min_width = @intCast(fb_w);
    hints.min_height = @intCast(fb_h + chrome_h);
    hints.width_inc = @intCast(fb_w);
    hints.height_inc = @intCast(fb_h);
    hints.base_width = 0;
    hints.base_height = @intCast(chrome_h);
    XSetWMNormalHints(x.dpy, x.win, &hints);
    _ = XFlush(x.dpy);
}
