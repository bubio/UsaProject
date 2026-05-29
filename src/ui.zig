const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const cz = @import("c.zig");
const nfd = @import("nfd.zig");
const nk = @import("nk.zig");
const c = nk.c;
const ui_dialog = @import("ui_dialog.zig");
const platform = @import("platform.zig");
const cli = @import("cli.zig");

pub const MENU_HEIGHT: u32 = 26;
pub const STATUS_HEIGHT: u32 = 22;

const FB_WIDTH: u32 = 640;
const FB_HEIGHT: u32 = 400;
const CHROME: u32 = MENU_HEIGHT + STATUS_HEIGHT;

// Last scale the user asked for; restored when leaving fullscreen.
var user_scale: u32 = 1;
var was_fullscreen: bool = false;

fn applyScale(n: u32) void {
    platform.os.setWindowSize(FB_WIDTH * n, FB_HEIGHT * n + CHROME);
}

fn setWindowScale(n: u32) void {
    user_scale = n;
    applyScale(n);
}

// Largest uniform integer multiple that the current window size rounds to.
fn scaleFor(w: u32, h: u32) u32 {
    const wn = (w + FB_WIDTH / 2) / FB_WIDTH;
    const avail: u32 = if (h > CHROME) h - CHROME else 0;
    const hn = (avail + FB_HEIGHT / 2) / FB_HEIGHT;
    const n = @min(wn, hn);
    return if (n < 1) 1 else n;
}

/// Keep the window pinned to a uniform integer scale. Per-axis native resize
/// increments still apply during a drag, but they allow the two axes to scale
/// independently; here we re-unify them. On leaving fullscreen we restore the
/// scale the user had before, which AppKit does not reliably do on its own.
pub fn enforceWindowConstraints() void {
    if (sapp.isFullscreen()) {
        was_fullscreen = true;
        return;
    }
    if (was_fullscreen) {
        was_fullscreen = false;
        applyScale(user_scale);
        return;
    }
    const w: u32 = @intCast(sapp.width());
    const h: u32 = @intCast(sapp.height());
    const n = scaleFor(w, h);
    if (w != FB_WIDTH * n or h != FB_HEIGHT * n + CHROME) {
        user_scale = n;
        applyScale(n);
    }
}

pub const State = struct {
    fps: f32 = 0.0,
    cpu_mhz: f32 = 0.0,
    fdd_access: [4]bool = .{ false, false, false, false },
    model: []const u8 = "",
};

// Build an nfd filter spec ("fdi,d88,...") from cli's "*.ext" lists so the
// dialog and the CLI argument parser accept exactly the same formats.
fn extsToSpec(comptime exts: []const []const u8) [:0]const u8 {
    comptime {
        var body: []const u8 = "";
        for (exts, 0..) |ext, i| {
            if (i != 0) body = body ++ ",";
            body = body ++ ext[1..]; // drop the leading '.'
        }
        const terminated = body ++ "\x00";
        return terminated[0 .. terminated.len - 1 :0];
    }
}

const fdd_filters = [_]nfd.Filter{
    .{ .name = "FDD Images", .spec = extsToSpec(&cli.fdd_exts) },
};
const hdd_filters = [_]nfd.Filter{
    .{ .name = "HDD Images", .spec = extsToSpec(&cli.hdd_exts) },
};

const PendingAction = enum {
    none,
    open_fdd0,
    open_fdd1,
    open_hdd0,
    open_hdd1,
};
var pending: PendingAction = .none;
var dialog_open: bool = false;

var about_icon: c.snk_image_t = .{};
var about_icon_valid: bool = false;

const app_icon_raw = @embedFile("AppIcon128.raw");

pub fn setup() void {
    var img_desc: sg.ImageDesc = .{
        .width = 128,
        .height = 128,
        .pixel_format = .RGBA8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = app_icon_raw.ptr,
        .size = app_icon_raw.len,
    };
    const image = sg.makeImage(img_desc);

    const view = sg.makeView(.{
        .texture = .{ .image = image },
    });
    const sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
    });

    const desc = c.snk_image_desc_t{
        .texture_view = @bitCast(view),
        .sampler = @bitCast(sampler),
    };
    about_icon = c.snk_make_image(&desc);
    about_icon_valid = true;
}

pub fn shutdown() void {
    if (about_icon_valid) {
        c.snk_destroy_image(about_icon);
        about_icon_valid = false;
    }
}

var style_patched: bool = false;

fn clearMouseClick(ctx: *c.nk_context) void {
    ctx.input.mouse.buttons[c.NK_BUTTON_LEFT].clicked = 0;
    ctx.input.mouse.buttons[c.NK_BUTTON_LEFT].down = 0;
}

pub fn draw(ctx: *c.nk_context, win_w: u32, win_h: u32, st: State) void {
    if (!style_patched) {
        style_patched = true;
        ctx.style.checkbox.cursor_normal = c.nk_style_item_color(c.nk_rgb(220, 220, 220));
        ctx.style.checkbox.cursor_hover = c.nk_style_item_color(c.nk_rgb(255, 255, 255));
        // snk_setup() unconditionally loads Nuklear's software cursors, so Nuklear
        // draws its own arrow on top of the host OS cursor (double cursor). We rely
        // on the host cursor for menu interaction, so suppress Nuklear's drawn one.
        c.nk_style_hide_cursor(ctx);
    }
    drawMenuBar(ctx, win_w);
    drawStatusBar(ctx, win_w, win_h, st);
    if (ui_dialog.show_about) drawAbout(ctx, win_w, win_h);
    ui_dialog.draw(ctx, win_w, win_h);
}

pub fn flushPendingActions() void {
    if (dialog_open) return;
    const action = pending;
    pending = .none;
    if (action == .none) return;

    dialog_open = true;
    defer dialog_open = false;

    switch (action) {
        .open_fdd0 => openFdd(0),
        .open_fdd1 => openFdd(1),
        .open_hdd0 => openHdd(0),
        .open_hdd1 => openHdd(1),
        .none => {},
    }
}

// --- Helper: format checked/radio labels ---

fn checkLabel(buf: *[64]u8, checked: bool, label: []const u8) [*:0]const u8 {
    const prefix: []const u8 = if (checked) "[*] " else "[ ] ";
    const result = std.fmt.bufPrintZ(buf, "{s}{s}", .{ prefix, label }) catch "?";
    return result.ptr;
}

fn radioLabel(buf: *[64]u8, selected: bool, label: []const u8) [*:0]const u8 {
    const prefix: []const u8 = if (selected) "(*) " else "( ) ";
    const result = std.fmt.bufPrintZ(buf, "{s}{s}", .{ prefix, label }) catch "?";
    return result.ptr;
}

// --- Menu Bar ---

fn drawMenuBar(ctx: *c.nk_context, win_w: u32) void {
    const w: f32 = @floatFromInt(win_w);
    const h: f32 = @floatFromInt(MENU_HEIGHT);
    const bounds = c.nk_rect(0, 0, w, h);

    c.nk_window_set_bounds(ctx, "MenuBar", bounds);
    if (c.nk_begin(ctx, "MenuBar", bounds, c.NK_WINDOW_NO_SCROLLBAR | c.NK_WINDOW_BACKGROUND) != 0) {
        c.nk_menubar_begin(ctx);
        c.nk_layout_row_begin(ctx, c.NK_STATIC, h - 8, 5);

        menuEmulate(ctx);
        menuFdd(ctx);
        menuHdd(ctx);
        menuScreen(ctx);
        menuOther(ctx);

        c.nk_layout_row_end(ctx);
        c.nk_menubar_end(ctx);
    }
    c.nk_end(ctx);
}

fn menuEmulate(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 65);
    if (c.nk_menu_begin_label(ctx, "Emulate", c.NK_TEXT_LEFT, c.nk_vec2(180, 120)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Reset", c.NK_TEXT_LEFT) != 0) {
            cz.pccore_reset();
        }
        if (c.nk_menu_item_label(ctx, "Configure...", c.NK_TEXT_LEFT) != 0) {
            ui_dialog.openConfigure();
            clearMouseClick(ctx);
        }
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Exit", c.NK_TEXT_LEFT) != 0) sapp.requestQuit();
        c.nk_menu_end(ctx);
    }
}

fn menuFdd(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 45);
    if (c.nk_menu_begin_label(ctx, "FDD", c.NK_TEXT_LEFT, c.nk_vec2(180, 180)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open FDD1...", c.NK_TEXT_LEFT) != 0) { pending = .open_fdd0; }
        if (c.nk_menu_item_label(ctx, "Eject FDD1", c.NK_TEXT_LEFT) != 0) ejectFdd(0);
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open FDD2...", c.NK_TEXT_LEFT) != 0) { pending = .open_fdd1; }
        if (c.nk_menu_item_label(ctx, "Eject FDD2", c.NK_TEXT_LEFT) != 0) ejectFdd(1);
        c.nk_menu_end(ctx);
    }
}

fn menuHdd(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 45);
    if (c.nk_menu_begin_label(ctx, "HDD", c.NK_TEXT_LEFT, c.nk_vec2(180, 180)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open IDE0...", c.NK_TEXT_LEFT) != 0) { pending = .open_hdd0; }
        if (c.nk_menu_item_label(ctx, "Eject IDE0", c.NK_TEXT_LEFT) != 0) ejectHdd(0);
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open IDE1...", c.NK_TEXT_LEFT) != 0) { pending = .open_hdd1; }
        if (c.nk_menu_item_label(ctx, "Eject IDE1", c.NK_TEXT_LEFT) != 0) ejectHdd(1);
        c.nk_menu_end(ctx);
    }
}

fn menuScreen(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 60);
    if (c.nk_menu_begin_label(ctx, "Screen", c.NK_TEXT_LEFT, c.nk_vec2(160, 220)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "FullScreen", c.NK_TEXT_LEFT) != 0) {
            sapp.toggleFullscreen();
        }
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Window x1", c.NK_TEXT_LEFT) != 0) setWindowScale(1);
        if (c.nk_menu_item_label(ctx, "Window x2", c.NK_TEXT_LEFT) != 0) setWindowScale(2);
        if (c.nk_menu_item_label(ctx, "Window x3", c.NK_TEXT_LEFT) != 0) setWindowScale(3);
        if (c.nk_menu_item_label(ctx, "Window x4", c.NK_TEXT_LEFT) != 0) setWindowScale(4);
        c.nk_menu_end(ctx);
    }
}

fn menuOther(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 50);
    if (c.nk_menu_begin_label(ctx, "Other", c.NK_TEXT_LEFT, c.nk_vec2(160, 80)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "About...", c.NK_TEXT_LEFT) != 0) {
            ui_dialog.openAbout();
            clearMouseClick(ctx);
        }
        c.nk_menu_end(ctx);
    }
}

// --- Status Bar ---

fn drawStatusBar(ctx: *c.nk_context, win_w: u32, win_h: u32, st: State) void {
    const y: f32 = @floatFromInt(win_h - STATUS_HEIGHT);
    const w: f32 = @floatFromInt(win_w);
    const h: f32 = @floatFromInt(STATUS_HEIGHT);
    const bounds = c.nk_rect(0, y, w, h);

    c.nk_window_set_bounds(ctx, "StatusBar", bounds);
    if (c.nk_begin(ctx, "StatusBar", bounds, c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        c.nk_layout_row_template_begin(ctx, h - 4);
        c.nk_layout_row_template_push_static(ctx, 180);
        c.nk_layout_row_template_push_variable(ctx, 100);
        c.nk_layout_row_template_push_static(ctx, 80);
        c.nk_layout_row_template_end(ctx);

        var mbuf: [48]u8 = undefined;
        const mline = std.fmt.bufPrintZ(&mbuf, "{s}  {d:.1}MHz", .{ st.model, st.cpu_mhz }) catch "?";
        c.nk_label(ctx, mline.ptr, c.NK_TEXT_LEFT);

        drawFddLamps(ctx, st.fdd_access);

        var fbuf: [16]u8 = undefined;
        const fline = std.fmt.bufPrintZ(&fbuf, "{d:.1} FPS", .{st.fps}) catch "? FPS";
        c.nk_label(ctx, fline.ptr, c.NK_TEXT_RIGHT);
    }
    c.nk_end(ctx);
}

fn drawFddLamps(ctx: *c.nk_context, access: [4]bool) void {
    const canvas = c.nk_window_get_canvas(ctx);
    var bounds: c.struct_nk_rect = undefined;
    _ = c.nk_widget(&bounds, ctx);

    const lamp_w: f32 = 12;
    const lamp_h: f32 = 10;
    const gap: f32 = 6;
    const label_w: f32 = 36;
    const lamp_y = bounds.y + (bounds.h - lamp_h) / 2.0;

    const active_color = c.nk_rgb(0xFF, 0x60, 0x10);
    const dim_color = c.nk_rgb(0x40, 0x18, 0x08);
    const text_color = c.nk_rgb(0xD0, 0xD0, 0xD0);

    const font = ctx.style.font;
    c.nk_draw_text(canvas, c.nk_rect(bounds.x, bounds.y, label_w, bounds.h), "FDD:", 4, font, c.nk_rgb(0, 0, 0), text_color);

    for (0..4) |i| {
        const fi: f32 = @floatFromInt(i);
        const lx = bounds.x + label_w + fi * (lamp_w + gap);
        const color = if (access[i]) active_color else dim_color;
        c.nk_fill_rect(canvas, c.nk_rect(lx, lamp_y, lamp_w, lamp_h), 0, color);
    }
}

// --- About Dialog ---

fn drawAbout(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 340;
    const dh: f32 = 130;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_CLOSABLE | c.NK_WINDOW_NO_SCROLLBAR;

    c.nk_window_show(ctx, "About UsaProject", c.NK_SHOWN);
    if (ui_dialog.reopen_about) {
        ui_dialog.reopen_about = false;
        c.nk_window_set_bounds(ctx, "About UsaProject", bounds);
    }

    if (c.nk_begin(ctx, "About UsaProject", bounds, flags) != 0) {
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 80, 2);

        if (about_icon_valid) {
            c.nk_layout_row_push(ctx, 80);
            c.nk_image(ctx, c.nk_image_handle(c.snk_nkhandle(about_icon)));
        }

        c.nk_layout_row_push(ctx, 220);
        if (c.nk_group_begin(ctx, "about_text", c.NK_WINDOW_NO_SCROLLBAR) != 0) {
            c.nk_layout_row_dynamic(ctx, 20, 1);
            c.nk_label(ctx, "UsaProject", c.NK_TEXT_LEFT);
            c.nk_label(ctx, "Version: 0.1.0", c.NK_TEXT_LEFT);
            c.nk_label(ctx, "Core: NP2kai 0.86", c.NK_TEXT_LEFT);
            c.nk_group_end(ctx);
        }

        c.nk_layout_row_end(ctx);
    }
    c.nk_end(ctx);
    if (c.nk_window_is_hidden(ctx, "About UsaProject") != 0) {
        ui_dialog.show_about = false;
    }
}

// --- Disk Operations ---

const disk_alloc = std.heap.page_allocator;

fn openFdd(drv: u32) void {
    if (nfd.openDialog(disk_alloc, &fdd_filters) catch null) |path| {
        defer disk_alloc.free(path);
        cz.np2_insert_fdd(drv, path.ptr);
    }
}

fn openHdd(drv: u32) void {
    if (nfd.openDialog(disk_alloc, &hdd_filters) catch null) |path| {
        defer disk_alloc.free(path);
        cz.np2_insert_hdd(drv, path.ptr);
        // HDD changes are only picked up by diskdrv_hddbind(), which runs as
        // part of a machine reset — reboot so the new image is recognized.
        cz.pccore_reset();
    }
}

fn ejectFdd(drv: u32) void {
    cz.np2_eject_fdd(drv);
}

fn ejectHdd(drv: u32) void {
    cz.np2_eject_hdd(drv);
    // Reboot so the machine comes back up without the ejected drive.
    cz.pccore_reset();
}
