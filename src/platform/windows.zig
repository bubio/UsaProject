const std = @import("std");
const sapp = @import("sokol").app;

pub const shader_vs_source = @embedFile("shaders/blit.vs.hlsl");
pub const shader_fs_source = @embedFile("shaders/blit.fs.hlsl");
pub const shader_entry = "main";

// Backslashes (not forward slashes): the path is handed to `explorer` to
// reveal the folder, and Explorer only parses backslash-separated paths —
// given forward slashes it ignores the argument and opens Documents instead.
// Win32 file APIs accept either separator, so the rest of the code is unaffected.
pub const data_dir_template = "{s}\\AppData\\Local\\{s}";

// Command that reveals a file or folder in the OS file manager (Explorer).
pub const open_cmd = "explorer";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("USERPROFILE");
}

pub fn monotonicNs() i128 {
    const windows = std.os.windows;
    var qpf: windows.LARGE_INTEGER = undefined;
    _ = windows.ntdll.RtlQueryPerformanceFrequency(&qpf);
    var qpc: windows.LARGE_INTEGER = undefined;
    _ = windows.ntdll.RtlQueryPerformanceCounter(&qpc);
    const f: i128 = @intCast(qpf);
    const c: i128 = @intCast(qpc);
    return @divTrunc(c * std.time.ns_per_s, f);
}

/// Baseline scale for locked-mode relative mouse deltas, treated as the "100%"
/// sensitivity that the user setting multiplies. While the mouse is locked,
/// sokol feeds raw device counts (mickeys) straight through with no pointer
/// acceleration, so the emulated cursor is far more sensitive than the host
/// pointer; this damps it toward desktop feel. Fine-tuning is done at runtime
/// via the Configure dialog's Mouse sensitivity slider, so this only sets the
/// default operating point.
pub fn mouseScale() f32 {
    return 0.03;
}

// --- Native window control via Win32 ---

const win = std.os.windows;
const WINAPI: std.builtin.CallingConvention = .winapi;
const HWND = win.HWND;

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const POINT = extern struct { x: i32, y: i32 };
const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

const GWL_STYLE: i32 = -16;
const GWL_EXSTYLE: i32 = -20;
const GWLP_WNDPROC: i32 = -4;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const WM_SIZING: u32 = 0x0214;
const WM_GETMINMAXINFO: u32 = 0x0024;
// WM_SIZING wParam edge codes.
const WMSZ_LEFT: usize = 1;
const WMSZ_TOP: usize = 3;
const WMSZ_TOPLEFT: usize = 4;
const WMSZ_TOPRIGHT: usize = 5;
const WMSZ_BOTTOMLEFT: usize = 7;

extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(WINAPI) isize;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, val: isize) callconv(WINAPI) isize;
extern "user32" fn AdjustWindowRectEx(rect: *RECT, style: u32, menu: i32, ex_style: u32) callconv(WINAPI) i32;
extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(WINAPI) i32;
extern "user32" fn CallWindowProcW(prev: *const anyopaque, hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(WINAPI) isize;

var prev_wndproc: ?*const anyopaque = null;
var step_w: u32 = 1;
var step_h: u32 = 1;
var chrome: u32 = 0;

fn ncBorders(hwnd: HWND) struct { w: i32, h: i32 } {
    const style: u32 = @bitCast(@as(i32, @truncate(GetWindowLongPtrW(hwnd, GWL_STYLE))));
    const ex_style: u32 = @bitCast(@as(i32, @truncate(GetWindowLongPtrW(hwnd, GWL_EXSTYLE))));
    var r = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = AdjustWindowRectEx(&r, style, 0, ex_style);
    return .{ .w = r.right - r.left, .h = r.bottom - r.top };
}

fn snap(client: i32, base: i32, inc: i32) i32 {
    if (inc <= 0) return client;
    const usable = client - base;
    if (usable <= inc) return base + inc;
    const n = @divTrunc(usable + @divTrunc(inc, 2), inc);
    return base + n * inc;
}

fn subclassProc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(WINAPI) isize {
    switch (msg) {
        WM_GETMINMAXINFO => {
            const b = ncBorders(hwnd);
            const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            mmi.ptMinTrackSize.x = @as(i32, @intCast(step_w)) + b.w;
            mmi.ptMinTrackSize.y = @as(i32, @intCast(step_h + chrome)) + b.h;
            return 0;
        },
        WM_SIZING => {
            const b = ncBorders(hwnd);
            const r: *RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const win_w = r.right - r.left;
            const win_h = r.bottom - r.top;
            const new_w = snap(win_w - b.w, 0, @intCast(step_w)) + b.w;
            const new_h = snap(win_h - b.h, @intCast(chrome), @intCast(step_h)) + b.h;
            // Keep the dragged edge anchored.
            switch (wparam) {
                WMSZ_LEFT, WMSZ_TOPLEFT, WMSZ_BOTTOMLEFT => r.left = r.right - new_w,
                else => r.right = r.left + new_w,
            }
            switch (wparam) {
                WMSZ_TOP, WMSZ_TOPLEFT, WMSZ_TOPRIGHT => r.top = r.bottom - new_h,
                else => r.bottom = r.top + new_h,
            }
            return 1; // TRUE: we adjusted the rect
        },
        else => {},
    }
    return CallWindowProcW(prev_wndproc.?, hwnd, msg, wparam, lparam);
}

/// Resize the window's client area (in pixels), keeping its position.
pub fn setWindowSize(w: u32, h: u32) void {
    if (sapp.isFullscreen()) return;
    const hwnd: HWND = @ptrCast(@constCast(sapp.win32GetHwnd() orelse return));
    const b = ncBorders(hwnd);
    _ = SetWindowPos(hwnd, null, 0, 0, @as(i32, @intCast(w)) + b.w, @as(i32, @intCast(h)) + b.h, SWP_NOMOVE | SWP_NOZORDER);
}

/// Constrain interactive resizing to integer multiples of the screen by
/// subclassing the window procedure (survives sokol's fullscreen restyle).
pub fn lockWindow(fb_w: u32, fb_h: u32, chrome_h: u32) void {
    const hwnd: HWND = @ptrCast(@constCast(sapp.win32GetHwnd() orelse return));
    step_w = fb_w;
    step_h = fb_h;
    chrome = chrome_h;
    if (prev_wndproc != null) return; // already installed
    const old = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, @bitCast(@intFromPtr(&subclassProc)));
    prev_wndproc = @ptrFromInt(@as(usize, @bitCast(old)));
}
