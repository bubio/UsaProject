const std = @import("std");
const sapp = @import("sokol").app;

pub const shader_vs_source = @embedFile("shaders/blit.vs.metal");
pub const shader_fs_source = @embedFile("shaders/blit.fs.metal");
pub const shader_entry = "_main";

pub const data_dir_template = "{s}/Library/Application Support/{s}";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("HOME");
}

pub fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// --- Native window control via the Objective-C runtime ---

const Id = ?*const anyopaque;
const Sel = ?*anyopaque;

const NSSize = extern struct { width: f64, height: f64 };

extern "c" fn objc_msgSend() void;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;

fn sendSize(obj: Id, sel: Sel, size: NSSize) void {
    const f: *const fn (Id, Sel, NSSize) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel, size);
}

fn sendVoid(obj: Id, sel: Sel) void {
    const f: *const fn (Id, Sel) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel);
}

/// Resize the window's content area (in points) and recenter it on screen.
pub fn setWindowSize(w: u32, h: u32) void {
    const win = sapp.macosGetWindow() orelse return;
    if (sapp.isFullscreen()) return; // ignore while in fullscreen
    sendSize(win, sel_registerName("setContentSize:"), .{
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    });
    sendVoid(win, sel_registerName("center"));
}

/// Constrain interactive resizing to integer multiples of the screen.
/// The window stays resizable (required for native fullscreen to scale the
/// content), but the content size can only land on the 640x400 step grid:
/// width = fb_w*N, height = fb_h*N + chrome_h.
pub fn lockWindow(fb_w: u32, fb_h: u32, chrome_h: u32) void {
    const win = sapp.macosGetWindow() orelse return;
    sendSize(win, sel_registerName("setContentMinSize:"), .{
        .width = @floatFromInt(fb_w),
        .height = @floatFromInt(fb_h + chrome_h),
    });
    sendSize(win, sel_registerName("setContentResizeIncrements:"), .{
        .width = @floatFromInt(fb_w),
        .height = @floatFromInt(fb_h),
    });
}
