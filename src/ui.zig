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
const archive = @import("archive.zig");
const input = @import("input.zig");
const history = @import("history.zig");

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
    hdd_access: [4]bool = .{ false, false, false, false },
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
    .{ .name = "Archives (zip)", .spec = extsToSpec(&cli.archive_exts) },
};
const hdd_filters = [_]nfd.Filter{
    .{ .name = "HDD Images", .spec = extsToSpec(&cli.hdd_exts) },
    .{ .name = "Archives (zip)", .spec = extsToSpec(&cli.archive_exts) },
};
const state_filters = [_]nfd.Filter{
    .{ .name = "State Files", .spec = "sav" },
};

const PendingAction = enum {
    none,
    open_fdd0,
    open_fdd1,
    open_fdd_both,
    open_hdd0,
    open_hdd1,
    save_state,
    load_state,
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
    if (pending_state_path) |p| disk_alloc.free(p);
    freeSlots();
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
    if (ds_active()) drawDiskSelect(ctx, win_w, win_h);
    if (rs_active()) drawRecentSelect(ctx, win_w, win_h);
    if (ss_active()) drawStateMsg(ctx, win_w, win_h);
    ui_dialog.draw(ctx, win_w, win_h);
}

pub fn flushPendingActions() void {
    if (dialog_open) return;
    // While a modal is up, don't start another file dialog.
    if (ds_active() or rs_active() or ss_active()) {
        pending = .none;
        return;
    }
    const action = pending;
    pending = .none;
    if (action == .none) return;

    dialog_open = true;
    defer dialog_open = false;

    switch (action) {
        .open_fdd0 => openSingle(.fdd, 0),
        .open_fdd1 => openSingle(.fdd, 1),
        .open_fdd_both => openFddBoth(),
        .open_hdd0 => openSingle(.hdd, 0),
        .open_hdd1 => openSingle(.hdd, 1),
        .save_state => saveState(),
        .load_state => loadState(),
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
    if (c.nk_menu_begin_label(ctx, "Emulate", c.NK_TEXT_LEFT, c.nk_vec2(180, 200)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Reset", c.NK_TEXT_LEFT) != 0) {
            cz.pccore_reset();
        }
        if (c.nk_menu_item_label(ctx, "Configure...", c.NK_TEXT_LEFT) != 0) {
            ui_dialog.openConfigure();
            clearMouseClick(ctx);
        }
        menuSep(ctx);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        // Deferred like the disk dialogs: just set `pending`; the native dialog
        // runs in flushPendingActions so it doesn't fight the menu's click.
        if (c.nk_menu_item_label(ctx, "Save State...", c.NK_TEXT_LEFT) != 0) pending = .save_state;
        if (c.nk_menu_item_label(ctx, "Load State...", c.NK_TEXT_LEFT) != 0) pending = .load_state;
        menuSep(ctx);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Exit", c.NK_TEXT_LEFT) != 0) sapp.requestQuit();
        c.nk_menu_end(ctx);
    }
}

// Map a drive to the deferred "open file dialog" action for it.
fn pendingOpen(kind: cli.DiskKind, drv: u32) PendingAction {
    return switch (kind) {
        .fdd => if (drv == 0) .open_fdd0 else .open_fdd1,
        .hdd => if (drv == 0) .open_hdd0 else .open_hdd1,
        .archive => .none,
    };
}

fn menuSep(ctx: *c.nk_context) void {
    c.nk_layout_row_dynamic(ctx, 4, 1);
    c.nk_spacing(ctx, 1);
}

// Nuklear advances each row by `row_height + style.window.spacing.y` (default
// 4) and starts the panel one top padding (default 4) in. The menu can't
// scroll, so the popup must be tall enough for every row or the last item is
// clipped. We size by summing rowH() per row and add MENU_SLACK on top to
// absorb top/bottom padding plus rounding; the surplus is just empty space at
// the popup's bottom and stays well within the window height.
const NK_SPACING_Y: f32 = 4;
const MENU_SLACK: f32 = 30;

// Height consumed by one row of content height `h` (the row plus the spacing
// Nuklear inserts after it).
fn rowH(h: f32) f32 {
    return h + NK_SPACING_Y;
}

// Pixel height a drive's section needs. The menu shows a compact block: header
// + Open + Eject, then either the clickable source name plus the mounted disk,
// or the "(empty)" line.
fn sectionHeight(kind: cli.DiskKind, drv: u32) f32 {
    var h: f32 = rowH(18) + rowH(22) + rowH(22) + rowH(22); // header + Open + Eject + Recent
    h += if (slotsFor(kind)[drv].set != null) rowH(22) + rowH(18) else rowH(18);
    return h;
}

// One drive's block inside a drive menu: a non-clickable header, Open/Eject,
// then (if loaded) the clickable source name — which opens the scrollable disk-
// selection modal for swapping — and a label showing the mounted disk.
fn driveSection(ctx: *c.nk_context, kind: cli.DiskKind, drv: u32, title: [*:0]const u8) void {
    // Centered so the non-selectable drive header reads differently from the
    // left-aligned, clickable items below it.
    c.nk_layout_row_dynamic(ctx, 18, 1);
    c.nk_label(ctx, title, c.NK_TEXT_CENTERED);

    c.nk_layout_row_dynamic(ctx, 22, 1);
    if (c.nk_menu_item_label(ctx, "Open...", c.NK_TEXT_LEFT) != 0) pending = pendingOpen(kind, drv);
    if (c.nk_menu_item_label(ctx, "Eject", c.NK_TEXT_LEFT) != 0) {
        switch (kind) {
            .fdd => ejectFdd(drv),
            .hdd => ejectHdd(drv),
            .archive => {},
        }
    }
    // Recent: opens the scrollable history list, mounting the pick into THIS
    // drive. An in-app modal (not a native dialog), so trigger it directly.
    if (c.nk_menu_item_label(ctx, "Recent...", c.NK_TEXT_LEFT) != 0) openRecent(kind, drv);

    const slot = &slotsFor(kind)[drv];
    if (slot.set) |set| {
        // Clicking the source name opens the disk-selection modal to swap disks.
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, set.source.ptr, c.NK_TEXT_LEFT) != 0) openSwap(kind, drv);
        // The mounted disk (display only).
        c.nk_layout_row_dynamic(ctx, 18, 1);
        const cur_name: [*:0]const u8 = if (slot.current) |i| set.images[i].name.ptr else "(no disk)";
        c.nk_label(ctx, cur_name, c.NK_TEXT_RIGHT);
    } else {
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label(ctx, "(empty)", c.NK_TEXT_LEFT);
    }
}

fn menuFdd(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 45);
    // sections + two separators (rowH(4)) + the auto item (rowH(22)) + slack.
    const h = sectionHeight(.fdd, 0) + sectionHeight(.fdd, 1) +
        rowH(4) * 2 + rowH(22) + MENU_SLACK;
    if (c.nk_menu_begin_label(ctx, "FDD", c.NK_TEXT_LEFT, c.nk_vec2(230, h)) != 0) {
        driveSection(ctx, .fdd, 0, "FDD1");
        menuSep(ctx);
        driveSection(ctx, .fdd, 1, "FDD2");
        menuSep(ctx);
        // Batch convenience: mount a multi-disk archive's images, name-sorted,
        // into FDD1+FDD2 at once (the old auto-assign behavior).
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open FDD1+2 (auto)...", c.NK_TEXT_LEFT) != 0) {
            pending = .open_fdd_both;
        }
        c.nk_menu_end(ctx);
    }
}

fn menuHdd(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 45);
    // sections + one separator (rowH(4)) + slack.
    const h = sectionHeight(.hdd, 0) + sectionHeight(.hdd, 1) +
        rowH(4) + MENU_SLACK;
    if (c.nk_menu_begin_label(ctx, "HDD", c.NK_TEXT_LEFT, c.nk_vec2(230, h)) != 0) {
        driveSection(ctx, .hdd, 0, "IDE0");
        menuSep(ctx);
        driveSection(ctx, .hdd, 1, "IDE1");
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

// Width the drive-lamp group occupies: two groups ("FDD:" / "HDD:"), each a
// caption plus two lamps, with a gap between the groups. Must match the layout
// math in drawDriveLamps / drawLampGroup below.
const lamps_col_w: f32 = 150;
// Status-bar volume (master) range, mirroring np2cfg.vol_master (0..100).
const vol_max: f32 = 100;
// Volume to restore when the speaker icon un-mutes; tracked so a mute/unmute
// round-trip returns to the level the user had set.
var pre_mute_vol: u8 = 100;

fn drawStatusBar(ctx: *c.nk_context, win_w: u32, win_h: u32, st: State) void {
    const y: f32 = @floatFromInt(win_h - STATUS_HEIGHT);
    const w: f32 = @floatFromInt(win_w);
    const h: f32 = @floatFromInt(STATUS_HEIGHT);
    const bounds = c.nk_rect(0, y, w, h);

    c.nk_window_set_bounds(ctx, "StatusBar", bounds);
    // Inset the content from the window edges so the model text and FPS readout
    // are not flush against the left/right borders.
    _ = c.nk_style_push_vec2(ctx, &ctx.style.window.padding, c.nk_vec2(12, 2));
    defer _ = c.nk_style_pop_vec2(ctx);
    if (c.nk_begin(ctx, "StatusBar", bounds, c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        // Layout: Architecture | Clock | FDD/HDD | Volume ....(spacer).... Mouse | FPS.
        // Vertical bars are drawn as thin separator cells between groups.
        c.nk_layout_row_template_begin(ctx, h - 4);
        c.nk_layout_row_template_push_static(ctx, 44); // model (Architecture)
        c.nk_layout_row_template_push_static(ctx, 9); //  separator
        c.nk_layout_row_template_push_static(ctx, 66); // clock
        c.nk_layout_row_template_push_static(ctx, 9); //  separator
        c.nk_layout_row_template_push_static(ctx, lamps_col_w); // FDD/HDD lamps
        c.nk_layout_row_template_push_static(ctx, 9); //  separator
        c.nk_layout_row_template_push_static(ctx, 22); // volume (speaker) icon
        c.nk_layout_row_template_push_static(ctx, 80); // volume slider
        c.nk_layout_row_template_push_variable(ctx, 10); // flexible spacer
        c.nk_layout_row_template_push_static(ctx, 9); //  separator
        c.nk_layout_row_template_push_static(ctx, 24); // mouse-capture icon
        c.nk_layout_row_template_push_static(ctx, 9); //  separator
        c.nk_layout_row_template_push_static(ctx, 66); // FPS
        c.nk_layout_row_template_end(ctx);

        var mbuf: [16]u8 = undefined;
        const mline = std.fmt.bufPrintZ(&mbuf, "{s}", .{st.model}) catch "?";
        c.nk_label(ctx, mline.ptr, c.NK_TEXT_LEFT);
        drawSeparatorCell(ctx);

        var cbuf: [16]u8 = undefined;
        const cline = std.fmt.bufPrintZ(&cbuf, "{d:.1}MHz", .{st.cpu_mhz}) catch "?";
        c.nk_label(ctx, cline.ptr, c.NK_TEXT_LEFT);
        drawSeparatorCell(ctx);

        drawDriveLamps(ctx, st.fdd_access, st.hdd_access);
        drawSeparatorCell(ctx);

        drawVolumeIcon(ctx);
        drawVolumeSlider(ctx);

        c.nk_spacing(ctx, 1); // flexible spacer pushes the rest to the right edge
        drawSeparatorCell(ctx);

        drawMouseCaptureIcon(ctx);
        drawSeparatorCell(ctx);

        var fbuf: [16]u8 = undefined;
        const fline = std.fmt.bufPrintZ(&fbuf, "{d:.1} FPS", .{st.fps}) catch "? FPS";
        c.nk_label(ctx, fline.ptr, c.NK_TEXT_RIGHT);
    }
    c.nk_end(ctx);
}

// Consume one layout cell and stroke a thin vertical divider down its middle,
// rendering the "|" separators between status-bar groups.
fn drawSeparatorCell(ctx: *c.nk_context) void {
    const canvas = c.nk_window_get_canvas(ctx);
    var b: c.struct_nk_rect = undefined;
    _ = c.nk_widget(&b, ctx);
    const cx = b.x + b.w / 2.0;
    const pad: f32 = 3;
    c.nk_stroke_line(canvas, cx, b.y + pad, cx, b.y + b.h - pad, 1.0, c.nk_rgba(0xC0, 0xC0, 0xC0, 0x60));
}

// Speaker icon that doubles as a mute toggle. Filled bright when audible, dim
// with a red slash when muted (vol_master == 0). Clicking flips mute state.
fn drawVolumeIcon(ctx: *c.nk_context) void {
    const canvas = c.nk_window_get_canvas(ctx);
    var b: c.struct_nk_rect = undefined;
    _ = c.nk_widget(&b, ctx);

    const cfg = &cz.c.np2cfg;
    const muted = cfg.vol_master == 0;

    // Toggle mute on a click anywhere inside the icon cell.
    if (c.nk_input_is_mouse_click_in_rect(&ctx.input, c.NK_BUTTON_LEFT, b) != 0) {
        if (cfg.vol_master > 0) {
            pre_mute_vol = cfg.vol_master;
            cfg.vol_master = 0;
        } else {
            cfg.vol_master = if (pre_mute_vol > 0) pre_mute_vol else 100;
        }
        cz.usa_sound_apply_volumes();
    }

    const on_color = c.nk_rgb(0xD8, 0xD8, 0xD8);
    const off_color = c.nk_rgb(0x70, 0x70, 0x70);
    const col = if (muted) off_color else on_color;

    const cy = b.y + b.h / 2.0;
    const bx = b.x + 2;
    // Throat (small rectangle) + cone (trapezoid widening to the right).
    const throat_h: f32 = 6;
    c.nk_fill_rect(canvas, c.nk_rect(bx, cy - throat_h / 2.0, 4, throat_h), 0, col);
    const p = bx + 4;
    var pts = [_]f32{ p, cy - 3, p, cy + 3, p + 6, cy + 7, p + 6, cy - 7 };
    c.nk_fill_polygon(canvas, &pts, 4, col);

    if (muted) {
        // Red slash to signal muted.
        const sx = p + 9;
        const red = c.nk_rgb(0xE0, 0x40, 0x30);
        c.nk_stroke_line(canvas, sx, cy - 5, sx + 6, cy + 5, 1.5, red);
        c.nk_stroke_line(canvas, sx, cy + 5, sx + 6, cy - 5, 1.5, red);
    } else {
        // Two arcs as sound waves emanating from the cone.
        const ax = p + 6;
        c.nk_stroke_arc(canvas, ax, cy, 4, -0.7, 0.7, 1.0, col);
        c.nk_stroke_arc(canvas, ax, cy, 7, -0.7, 0.7, 1.0, col);
    }
}

fn drawVolumeSlider(ctx: *c.nk_context) void {
    const cfg = &cz.c.np2cfg;
    const cur = cfg.vol_master;
    var vf: f32 = @floatFromInt(cur);
    vf = c.nk_slide_float(ctx, 0, vf, vol_max, 1);
    const nv: u8 = @intFromFloat(vf);
    if (nv != cur) {
        cfg.vol_master = nv;
        if (nv > 0) pre_mute_vol = nv;
        cz.usa_sound_apply_volumes();
    }
}

// Mouse icon reflecting capture state: filled orange while the pointer is
// captured by the emulator, dim outline when free.
fn drawMouseCaptureIcon(ctx: *c.nk_context) void {
    const canvas = c.nk_window_get_canvas(ctx);
    var b: c.struct_nk_rect = undefined;
    _ = c.nk_widget(&b, ctx);

    const captured = input.isMouseCaptured();

    const mw: f32 = 12;
    const mh: f32 = 16;
    const mx = b.x + (b.w - mw) / 2.0;
    const my = b.y + (b.h - mh) / 2.0;
    const rounding: f32 = mw / 2.0;
    const body = c.nk_rect(mx, my, mw, mh);

    const active = c.nk_rgb(0xFF, 0x60, 0x10);
    const dim = c.nk_rgb(0x80, 0x80, 0x80);
    const outline = if (captured) active else dim;

    if (captured) c.nk_fill_rect(canvas, body, rounding, c.nk_rgb(0xC0, 0x4C, 0x0C));
    c.nk_stroke_rect(canvas, body, rounding, 1.0, outline);

    // Button split (horizontal) and the seam up to the top (vertical), giving
    // the silhouette a recognizable two-button mouse shape.
    const detail = if (captured) c.nk_rgb(0xFF, 0xFF, 0xFF) else dim;
    const cx = mx + mw / 2.0;
    const split_y = my + mh * 0.42;
    c.nk_stroke_line(canvas, mx, split_y, mx + mw, split_y, 1.0, detail);
    c.nk_stroke_line(canvas, cx, my, cx, split_y, 1.0, detail);
}

fn drawDriveLamps(ctx: *c.nk_context, fdd: [4]bool, hdd: [4]bool) void {
    const canvas = c.nk_window_get_canvas(ctx);
    var bounds: c.struct_nk_rect = undefined;
    _ = c.nk_widget(&bounds, ctx);

    var x = bounds.x;
    x = drawLampGroup(ctx, canvas, bounds, x, "FDD:", fdd);
    x += 18; // gap between the FDD and HDD groups
    _ = drawLampGroup(ctx, canvas, bounds, x, "HDD:", hdd);
}

// The GUI exposes two FDD and two HDD slots, so we show two lamps per group.
const lamp_count = 2;

// Draws a "LABEL:" caption followed by the access lamps starting at x, and
// returns the x just past the last lamp so groups can be laid out left to right.
fn drawLampGroup(ctx: *c.nk_context, canvas: *c.struct_nk_command_buffer, bounds: c.struct_nk_rect, x: f32, label: [*:0]const u8, access: [4]bool) f32 {
    const lamp_w: f32 = 12;
    const lamp_h: f32 = 10;
    const gap: f32 = 6;
    const label_w: f32 = 36;

    const active_color = c.nk_rgb(0xFF, 0x60, 0x10);
    const dim_color = c.nk_rgb(0x40, 0x18, 0x08);
    const text_color = c.nk_rgb(0xD0, 0xD0, 0xD0);

    // nk_draw_text renders the glyphs from the rect's top down by font height,
    // so center that band in the row to get a known text center line.
    const font = ctx.style.font;
    const font_h: f32 = font.*.height;
    const text_top = bounds.y + (bounds.h - font_h) / 2.0;
    c.nk_draw_text(canvas, c.nk_rect(x, text_top, label_w, font_h), label, 4, font, c.nk_rgb(0, 0, 0), text_color);

    // Center the lamps on the same center line as the text.
    const lamp_y = text_top + (font_h - lamp_h) / 2.0;
    const lamps_x = x + label_w;
    for (0..lamp_count) |i| {
        const fi: f32 = @floatFromInt(i);
        const lx = lamps_x + fi * (lamp_w + gap);
        const color = if (access[i]) active_color else dim_color;
        c.nk_fill_rect(canvas, c.nk_rect(lx, lamp_y, lamp_w, lamp_h), 0, color);
    }
    return lamps_x + lamp_count * (lamp_w + gap) - gap;
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
            c.nk_label(ctx, "Version: 0.2.0", c.NK_TEXT_LEFT);
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

// Per-drive mount state, so the drive menu can show what is loaded and offer
// the source's other disks as one-click swap targets. The GUI exposes two FDD
// and two HDD slots. Each Slot owns its ImageSet (the disk list + display
// names + source label); `current` indexes the mounted disk within it.
const Slot = struct {
    set: ?archive.ImageSet = null,
    current: ?usize = null,
};
var fdd_slots: [2]Slot = .{ .{}, .{} };
var hdd_slots: [2]Slot = .{ .{}, .{} };

fn slotsFor(kind: cli.DiskKind) *[2]Slot {
    return switch (kind) {
        .fdd => &fdd_slots,
        .hdd => &hdd_slots,
        .archive => unreachable,
    };
}

// Store `set` (taking ownership) into the drive's slot, freeing any prior set.
fn setSlot(kind: cli.DiskKind, drv: u32, set: archive.ImageSet, current: ?usize) void {
    if (drv >= 2) {
        var s = set;
        s.deinit();
        return;
    }
    const slot = &slotsFor(kind)[drv];
    if (slot.set) |*old| old.deinit();
    slot.* = .{ .set = set, .current = current };
}

fn clearSlot(kind: cli.DiskKind, drv: u32) void {
    if (drv >= 2) return;
    const slot = &slotsFor(kind)[drv];
    if (slot.set) |*old| old.deinit();
    slot.* = .{};
}

// Index of the image in `set` whose path equals `path`, if any.
fn indexOfPath(set: archive.ImageSet, path: []const u8) ?usize {
    for (set.images, 0..) |img, i| {
        if (std.mem.eql(u8, img.path, path)) return i;
    }
    return null;
}

fn insertOne(kind: cli.DiskKind, drv: u32, path: [*:0]const u8) void {
    switch (kind) {
        .fdd => cz.np2_insert_fdd(drv, path),
        .hdd => cz.np2_insert_hdd(drv, path),
        .archive => unreachable,
    }
}

// HDD changes are only picked up by diskdrv_hddbind(), which runs as part of a
// machine reset — reboot so a newly mounted/ejected image is recognized.
fn resetIfHdd(kind: cli.DiskKind) void {
    if (kind == .hdd) cz.pccore_reset();
}

// --- State save / load ---
//
// __LIBRETRO__ build: statsave_save_d/load_d take the path directly and do the
// real file I/O, so we run them at a frame boundary (flushPendingState, called
// from main.zig) rather than mid-frame from a menu click. The captured path is
// owned here in `pending_state_path` until the op runs.
const StateOp = enum { none, save, load };
var pending_state_op: StateOp = .none;
var pending_state_path: ?[:0]u8 = null;

// Take ownership of `path` and schedule `op` for the next frame boundary,
// replacing (and freeing) any previously queued request.
fn setPendingState(op: StateOp, path: [:0]u8) void {
    if (pending_state_path) |old| disk_alloc.free(old);
    pending_state_path = path;
    pending_state_op = op;
}

// Run a queued state save/load. Called from main.zig's frame loop on a frame
// boundary so the CPU is between steps when the (heavy) I/O happens.
pub fn flushPendingState() void {
    const op = pending_state_op;
    if (op == .none) return;
    pending_state_op = .none;
    const path = pending_state_path orelse return;
    pending_state_path = null;
    defer disk_alloc.free(path);
    switch (op) {
        .save => onStateSaveResult(cz.statsave_save_d(path.ptr)),
        .load => {
            const ret = cz.statsave_load_d(path.ptr);
            onStateLoadResult(ret);
            // The load swapped the core's mounted disks without going through the
            // UI's mount path, so rebuild the drive menus from the core's state.
            if (ret != cz.STATFLAG_FAILURE) syncSlotsFromCore();
        },
        .none => {},
    }
}

// Rebuild the drive-menu slots from the disks the core currently has mounted.
// Used after a state load, which changes the core's FDD/HDD contents directly.
fn syncSlotsFromCore() void {
    for (0..2) |i| {
        const drv: u32 = @intCast(i);
        syncSlot(.fdd, drv, cz.fdd_diskname(@intCast(i)));
        syncSlot(.hdd, drv, cz.sxsi_getfilename(@intCast(i)));
    }
}

// Point drive `drv`'s slot at `cname` (the core's mounted path): clear it, then
// rebuild the swap list from the file's folder. A NULL/empty name leaves it empty.
fn syncSlot(kind: cli.DiskKind, drv: u32, cname: [*c]u8) void {
    clearSlot(kind, drv);
    if (cname == null) return;
    const name = std.mem.span(cname);
    if (name.len == 0) return;
    registerMount(kind, drv, name);
}

// Save the current machine state to a path chosen via the native save dialog.
// The write itself runs at the next frame boundary (flushPendingState); a
// failure there surfaces via onStateSaveResult.
fn saveState() void {
    const path = (nfd.saveDialog(disk_alloc, &state_filters, "state.sav") catch null) orelse return;
    setPendingState(.save, path); // ownership moves to the pending slot
}

// Load a saved machine state. Picks a .sav via the open dialog, validates it
// with statsave_check, then either queues the load or raises an error/confirm
// modal depending on the compatibility flags.
fn loadState() void {
    const path = (nfd.openDialog(disk_alloc, &state_filters) catch null) orelse return;

    var buf: [1024]u8 = undefined;
    const ret = cz.statsave_check(path.ptr, &buf, @intCast(buf.len));

    // Hard error: failure, or a version/warning mismatch (anything but DISKCHG).
    if ((ret & ~cz.STATFLAG_DISKCHG) != 0) {
        disk_alloc.free(path);
        ss_showError("This file is not a valid save state, or is incompatible.");
        return;
    }
    // Disk mismatch only: ask before continuing (ss_showConfirm copies the path).
    if ((ret & cz.STATFLAG_DISKCHG) != 0) {
        ss_showConfirm(path);
        disk_alloc.free(path);
        return;
    }
    setPendingState(.load, path); // ownership moves to the pending slot
}

// Open a file dialog for `kind` and mount the selection into drive `drv`.
// A plain image mounts directly. An archive (.zip) is unpacked: if it holds a
// single image of `kind` that one is mounted; if it holds several, the disk-
// selection modal is shown so the user picks which disk goes into `drv`.
fn openSingle(kind: cli.DiskKind, drv: u32) void {
    const filters = if (kind == .fdd) &fdd_filters else &hdd_filters;
    const path = (nfd.openDialog(disk_alloc, filters) catch null) orelse return;
    defer disk_alloc.free(path);
    mountPath(kind, drv, path);
}

// Mount `path` (a dialog selection or a history entry) into drive `drv`. A plain
// image mounts directly; an archive (.zip) is unpacked, and either its single
// image of `kind` is mounted or the disk-selection modal is shown to pick one.
// On a successful open the original `path` is recorded in the recent history.
fn mountPath(kind: cli.DiskKind, drv: u32, path: [:0]const u8) void {
    if (!archive.isArchive(path)) {
        insertOne(kind, drv, path.ptr);
        resetIfHdd(kind);
        history.record(kind, path);
        // Build a swap list from the folder's sibling images. Best-effort: a
        // scan failure just leaves the drive mounted with no swap list.
        if (archive.scanFolder(disk_alloc, path, kind)) |set| {
            setSlot(kind, drv, set, indexOfPath(set, path));
        } else |_| clearSlot(kind, drv);
        return;
    }

    var set = archive.extractImages(disk_alloc, path) catch |err| {
        std.debug.print("!! could not open archive '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };

    var count: usize = 0;
    var only_index: ?usize = null;
    for (set.images, 0..) |img, i| {
        if (img.kind != kind) continue;
        count += 1;
        only_index = i;
    }

    switch (count) {
        0 => {
            std.debug.print("!! archive has no {s} image: {s}\n", .{ @tagName(kind), path });
            set.deinit();
        },
        1 => {
            const idx = only_index.?;
            insertOne(kind, drv, set.images[idx].path.ptr);
            resetIfHdd(kind);
            history.record(kind, path);
            setSlot(kind, drv, set, idx);
        },
        else => {
            // Hand ownership of `set` to the modal (initial-open mode); it frees
            // it on cancel, or commits it to the drive slot on choose.
            history.record(kind, path);
            ds_owned = set;
            ds_kind = kind;
            ds_target = drv;
            ds_on = true;
            ds_reopen = true;
        },
    }
}

// "Open FDD1+2 (auto)": mount the archive's FDD images, name-sorted, into FDD1
// and FDD2 (the two drives the GUI exposes). A plain image just goes to FDD1.
fn openFddBoth() void {
    const path = (nfd.openDialog(disk_alloc, &fdd_filters) catch null) orelse return;
    defer disk_alloc.free(path);

    if (!archive.isArchive(path)) {
        insertOne(.fdd, 0, path.ptr);
        history.record(.fdd, path);
        if (archive.scanFolder(disk_alloc, path, .fdd)) |set| {
            setSlot(.fdd, 0, set, indexOfPath(set, path));
        } else |_| clearSlot(.fdd, 0);
        return;
    }

    var set = archive.extractImages(disk_alloc, path) catch |err| {
        std.debug.print("!! could not open archive '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };

    // Mount up to 2 fdd images, name-sorted, into FDD1/FDD2, remembering which
    // image index each drive received.
    var mounted: [2]?usize = .{ null, null };
    var slot: u32 = 0;
    for (set.images, 0..) |img, i| {
        if (img.kind != .fdd) continue;
        if (slot >= 2) {
            std.debug.print("!! ignoring extra fdd image (FDD1+2 holds 2): {s}\n", .{img.path});
            break;
        }
        insertOne(.fdd, slot, img.path.ptr);
        mounted[slot] = i;
        slot += 1;
    }
    if (slot == 0) {
        std.debug.print("!! archive has no fdd image: {s}\n", .{path});
        set.deinit();
        return;
    }
    history.record(.fdd, path);

    // Give each occupied drive its own ImageSet so the menu can list the zip's
    // disks with the right one lit. FDD1 adopts the original set; FDD2 gets a
    // fresh extract (cache reuse keeps it cheap).
    setSlot(.fdd, 0, set, mounted[0].?);
    if (mounted[1]) |idx| {
        if (archive.extractImages(disk_alloc, path)) |s| {
            setSlot(.fdd, 1, s, idx);
        } else |_| clearSlot(.fdd, 1);
    }
}

// --- Disk-selection modal ---
//
// The drive menu can't scroll or overflow the window, so it shows only the
// mounted disk; this scrollable modal is where the full disk list lives. It is
// opened either on an initial multi-disk archive open, or by clicking the
// source name in the drive menu to swap disks.
//
// The drive slot owns its ImageSet. In swap mode the modal just borrows the
// slot's set. In initial-open mode the freshly-extracted set is not yet in a
// slot, so the modal owns it (`ds_owned`) until the user commits a choice.
var ds_on: bool = false;
var ds_kind: cli.DiskKind = .fdd;
var ds_target: u32 = 0;
var ds_owned: ?archive.ImageSet = null; // non-null => initial open; null => swap
var ds_reopen: bool = false;

fn ds_active() bool {
    return ds_on;
}

// Open the modal in swap mode for a drive that already holds a set.
fn openSwap(kind: cli.DiskKind, drv: u32) void {
    if (drv >= 2 or slotsFor(kind)[drv].set == null) return;
    ds_kind = kind;
    ds_target = drv;
    ds_owned = null;
    ds_on = true;
    ds_reopen = true;
}

fn drawDiskSelect(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    // The list source: the freshly-extracted set (initial open) or the drive's
    // existing set (swap). If neither is present, nothing to show.
    const set: *const archive.ImageSet = if (ds_owned) |*s|
        s
    else if (slotsFor(ds_kind)[ds_target].set) |*s|
        s
    else {
        ds_on = false;
        return;
    };
    const cur = slotsFor(ds_kind)[ds_target].current;

    const dw: f32 = 360;
    const dh: f32 = 300;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_CLOSABLE | c.NK_WINDOW_NO_SCROLLBAR;

    c.nk_window_show(ctx, "Select Disk", c.NK_SHOWN);
    if (ds_reopen) {
        ds_reopen = false;
        c.nk_window_set_bounds(ctx, "Select Disk", bounds);
    }

    var chosen: ?usize = null;
    var cancel = false;
    if (c.nk_begin(ctx, "Select Disk", bounds, flags) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, set.source.ptr, c.NK_TEXT_LEFT);

        c.nk_layout_row_dynamic(ctx, 200, 1);
        if (c.nk_group_begin(ctx, "ds_list", c.NK_WINDOW_BORDER) != 0) {
            c.nk_layout_row_dynamic(ctx, 26, 1);
            for (set.images, 0..) |img, i| {
                if (img.kind != ds_kind) continue;
                const lit = if (cur) |ci| ci == i else false;
                const sym: c_int = if (lit) c.NK_SYMBOL_CIRCLE_SOLID else c.NK_SYMBOL_NONE;
                if (c.nk_button_symbol_label(ctx, @intCast(sym), img.name.ptr, c.NK_TEXT_LEFT) != 0) chosen = i;
            }
            c.nk_group_end(ctx);
        }

        c.nk_layout_row_dynamic(ctx, 26, 1);
        if (c.nk_button_label(ctx, "Cancel") != 0) cancel = true;
    }
    c.nk_end(ctx);
    if (c.nk_window_is_hidden(ctx, "Select Disk") != 0) cancel = true;

    if (chosen) |idx| {
        insertOne(ds_kind, ds_target, set.images[idx].path.ptr);
        resetIfHdd(ds_kind);
        if (ds_owned) |_| {
            // Commit the owned set into the drive slot (frees any prior set).
            const owned = ds_owned.?;
            ds_owned = null;
            setSlot(ds_kind, ds_target, owned, idx);
        } else {
            slotsFor(ds_kind)[ds_target].current = idx;
        }
        ds_on = false;
    } else if (cancel) {
        // Initial-open cancel drops the freshly-extracted set (nothing mounted);
        // swap cancel leaves the slot untouched.
        if (ds_owned) |*s| {
            s.deinit();
            ds_owned = null;
        }
        ds_on = false;
    }
}

// --- Recent (history) modal ---
//
// Like the disk-selection modal, the drive menu can't scroll, so the recent
// list lives in this scrollable modal. Selecting an entry re-runs the normal
// open logic (mountPath) for the chosen drive: a plain image mounts, a multi-
// disk archive re-opens the disk-selection modal.
var rs_on: bool = false;
var rs_kind: cli.DiskKind = .fdd;
var rs_target: u32 = 0;
var rs_reopen: bool = false;

fn rs_active() bool {
    return rs_on;
}

fn openRecent(kind: cli.DiskKind, drv: u32) void {
    if (drv >= 2) return;
    rs_kind = kind;
    rs_target = drv;
    rs_on = true;
    rs_reopen = true;
}

fn drawRecentSelect(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 360;
    const dh: f32 = 300;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_CLOSABLE | c.NK_WINDOW_NO_SCROLLBAR;

    c.nk_window_show(ctx, "Recent Disks", c.NK_SHOWN);
    if (rs_reopen) {
        rs_reopen = false;
        c.nk_window_set_bounds(ctx, "Recent Disks", bounds);
    }

    var chosen: ?[:0]const u8 = null;
    var cancel = false;
    if (c.nk_begin(ctx, "Recent Disks", bounds, flags) != 0) {
        const title: [*:0]const u8 = if (rs_kind == .fdd) "FDD history" else "HDD history";
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, title, c.NK_TEXT_LEFT);

        const n = history.count(rs_kind);
        c.nk_layout_row_dynamic(ctx, 200, 1);
        if (c.nk_group_begin(ctx, "rs_list", c.NK_WINDOW_BORDER) != 0) {
            if (n == 0) {
                c.nk_layout_row_dynamic(ctx, 26, 1);
                c.nk_label(ctx, "(no recent)", c.NK_TEXT_LEFT);
            } else {
                c.nk_layout_row_dynamic(ctx, 26, 1);
                for (0..n) |i| {
                    const path = history.at(rs_kind, i);
                    const base = std.fs.path.basename(path);
                    var lbuf: [512]u8 = undefined;
                    const label = std.fmt.bufPrintZ(&lbuf, "{s}", .{base}) catch continue;
                    if (c.nk_button_label(ctx, label.ptr) != 0) chosen = path;
                }
            }
            c.nk_group_end(ctx);
        }

        c.nk_layout_row_dynamic(ctx, 26, 1);
        if (c.nk_button_label(ctx, "Cancel") != 0) cancel = true;
    }
    c.nk_end(ctx);
    if (c.nk_window_is_hidden(ctx, "Recent Disks") != 0) cancel = true;

    if (chosen) |path| {
        const kind = rs_kind;
        const drv = rs_target;
        rs_on = false;
        // mountPath may itself open the disk-selection modal (multi-disk zip).
        mountPath(kind, drv, path);
    } else if (cancel) {
        rs_on = false;
    }
}

// --- State save/load message modal ---
//
// A small modal shared by state save/load for two jobs: showing an error (a
// bad/incompatible file, or a failed save/load) with an OK button, and asking
// the user to confirm a load whose disk configuration differs from the save
// (STATFLAG_DISKCHG) with Load/Cancel buttons. Same state-variable + draw-hook +
// dialog-suppression structure as the disk/recent modals above.
const SsMode = enum { error_msg, confirm_load };
var ss_on: bool = false;
var ss_mode: SsMode = .error_msg;
var ss_reopen: bool = false;
var ss_text_buf: [256]u8 = undefined;
var ss_text_len: usize = 0;
// The load target held across the confirm modal, so we don't keep the dialog's
// heap-allocated path alive past loadState().
var ss_pending_path: [std.fs.max_path_bytes:0]u8 = undefined;
var ss_pending_path_len: usize = 0;

fn ss_active() bool {
    return ss_on;
}

fn ss_setText(msg: []const u8) void {
    ss_text_len = @min(msg.len, ss_text_buf.len);
    @memcpy(ss_text_buf[0..ss_text_len], msg[0..ss_text_len]);
}

fn ss_showError(msg: []const u8) void {
    ss_mode = .error_msg;
    ss_setText(msg);
    ss_on = true;
    ss_reopen = true;
}

fn ss_showConfirm(path: [:0]const u8) void {
    ss_mode = .confirm_load;
    ss_setText("The disk configuration differs from this save state. Load anyway?");
    ss_pending_path_len = @min(path.len, ss_pending_path.len);
    @memcpy(ss_pending_path[0..ss_pending_path_len], path[0..ss_pending_path_len]);
    ss_pending_path[ss_pending_path_len] = 0;
    ss_on = true;
    ss_reopen = true;
}

// Surface the result of the frame-boundary statsave_save_d/load_d. Only failures
// need user attention.
fn onStateSaveResult(ret: c_int) void {
    if (ret != cz.STATFLAG_SUCCESS) ss_showError("Failed to save the state.");
}

fn onStateLoadResult(ret: c_int) void {
    if (ret == cz.STATFLAG_FAILURE) ss_showError("Failed to load the state.");
}

fn drawStateMsg(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 360;
    const dh: f32 = 160;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_CLOSABLE | c.NK_WINDOW_NO_SCROLLBAR;

    const title: [*:0]const u8 = if (ss_mode == .error_msg) "State Error" else "Load State";
    c.nk_window_show(ctx, title, c.NK_SHOWN);
    if (ss_reopen) {
        ss_reopen = false;
        c.nk_window_set_bounds(ctx, title, bounds);
    }

    var do_load = false;
    var dismiss = false;
    if (c.nk_begin(ctx, title, bounds, flags) != 0) {
        var tbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&tbuf, "{s}", .{ss_text_buf[0..ss_text_len]}) catch "?";
        c.nk_layout_row_dynamic(ctx, 70, 1);
        c.nk_label_wrap(ctx, msg.ptr);

        if (ss_mode == .confirm_load) {
            c.nk_layout_row_dynamic(ctx, 26, 2);
            if (c.nk_button_label(ctx, "Cancel") != 0) dismiss = true;
            if (c.nk_button_label(ctx, "Load") != 0) do_load = true;
        } else {
            c.nk_layout_row_dynamic(ctx, 26, 1);
            if (c.nk_button_label(ctx, "OK") != 0) dismiss = true;
        }
    }
    c.nk_end(ctx);
    if (c.nk_window_is_hidden(ctx, title) != 0) dismiss = true;

    if (do_load) {
        ss_on = false;
        // Copy the held path into an owned slice for the pending slot.
        const p = disk_alloc.dupeZ(u8, ss_pending_path[0..ss_pending_path_len]) catch {
            ss_showError("Out of memory.");
            return;
        };
        setPendingState(.load, p);
    } else if (dismiss) {
        ss_on = false;
    }
}

fn ejectFdd(drv: u32) void {
    clearSlot(.fdd, drv);
    cz.np2_eject_fdd(drv);
}

fn ejectHdd(drv: u32) void {
    clearSlot(.hdd, drv);
    cz.np2_eject_hdd(drv);
    // Reboot so the machine comes back up without the ejected drive.
    cz.pccore_reset();
}

// Register an already-mounted disk (e.g. from CLI startup) so the menu shows
// its source's disk list. Best-effort: scans `path`'s folder for siblings.
pub fn registerMount(kind: cli.DiskKind, drv: u32, path: [:0]const u8) void {
    if (drv >= 2) return;
    if (archive.scanFolder(disk_alloc, path, kind)) |set| {
        setSlot(kind, drv, set, indexOfPath(set, path));
    } else |_| {}
}

// Free all drive slots; call at shutdown.
pub fn freeSlots() void {
    for (0..2) |i| {
        clearSlot(.fdd, @intCast(i));
        clearSlot(.hdd, @intCast(i));
    }
}
