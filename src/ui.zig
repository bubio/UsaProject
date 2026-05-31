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

const PendingAction = enum {
    none,
    open_fdd0,
    open_fdd1,
    open_fdd_both,
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
    if (ds_active()) drawDiskSelect(ctx, win_w, win_h);
    ui_dialog.draw(ctx, win_w, win_h);
}

pub fn flushPendingActions() void {
    if (dialog_open) return;
    // While the disk-selection modal is up, don't start another file dialog.
    if (ds_active()) {
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
    if (c.nk_menu_begin_label(ctx, "FDD", c.NK_TEXT_LEFT, c.nk_vec2(180, 230)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open FDD1...", c.NK_TEXT_LEFT) != 0) {
            pending = .open_fdd0;
        }
        if (c.nk_menu_item_label(ctx, "Eject FDD1", c.NK_TEXT_LEFT) != 0) ejectFdd(0);
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open FDD2...", c.NK_TEXT_LEFT) != 0) {
            pending = .open_fdd1;
        }
        if (c.nk_menu_item_label(ctx, "Eject FDD2", c.NK_TEXT_LEFT) != 0) ejectFdd(1);
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        // Batch convenience: mount a multi-disk archive's images, name-sorted,
        // into FDD1+FDD2 at once (the old auto-assign behavior).
        if (c.nk_menu_item_label(ctx, "Open FDD1+2 (auto)...", c.NK_TEXT_LEFT) != 0) {
            pending = .open_fdd_both;
        }
        c.nk_menu_end(ctx);
    }
}

fn menuHdd(ctx: *c.nk_context) void {
    c.nk_layout_row_push(ctx, 45);
    if (c.nk_menu_begin_label(ctx, "HDD", c.NK_TEXT_LEFT, c.nk_vec2(180, 180)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open IDE0...", c.NK_TEXT_LEFT) != 0) {
            pending = .open_hdd0;
        }
        if (c.nk_menu_item_label(ctx, "Eject IDE0", c.NK_TEXT_LEFT) != 0) ejectHdd(0);
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Open IDE1...", c.NK_TEXT_LEFT) != 0) {
            pending = .open_hdd1;
        }
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
    // Inset the content from the window edges so the model text and FPS readout
    // are not flush against the left/right borders.
    _ = c.nk_style_push_vec2(ctx, &ctx.style.window.padding, c.nk_vec2(12, 2));
    defer _ = c.nk_style_pop_vec2(ctx);
    if (c.nk_begin(ctx, "StatusBar", bounds, c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        c.nk_layout_row_template_begin(ctx, h - 4);
        c.nk_layout_row_template_push_static(ctx, 180);
        c.nk_layout_row_template_push_variable(ctx, 100);
        c.nk_layout_row_template_push_static(ctx, 80);
        c.nk_layout_row_template_end(ctx);

        var mbuf: [48]u8 = undefined;
        const mline = std.fmt.bufPrintZ(&mbuf, "{s}  {d:.1}MHz", .{ st.model, st.cpu_mhz }) catch "?";
        c.nk_label(ctx, mline.ptr, c.NK_TEXT_LEFT);

        drawDriveLamps(ctx, st.fdd_access, st.hdd_access);

        var fbuf: [16]u8 = undefined;
        const fline = std.fmt.bufPrintZ(&fbuf, "{d:.1} FPS", .{st.fps}) catch "? FPS";
        c.nk_label(ctx, fline.ptr, c.NK_TEXT_RIGHT);
    }
    c.nk_end(ctx);
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

// Open a file dialog for `kind` and mount the selection into drive `drv`.
// A plain image mounts directly. An archive (.zip) is unpacked: if it holds a
// single image of `kind` that one is mounted; if it holds several, the disk-
// selection modal is shown so the user picks which disk goes into `drv`.
fn openSingle(kind: cli.DiskKind, drv: u32) void {
    const filters = if (kind == .fdd) &fdd_filters else &hdd_filters;
    const path = (nfd.openDialog(disk_alloc, filters) catch null) orelse return;
    defer disk_alloc.free(path);

    if (!archive.isArchive(path)) {
        insertOne(kind, drv, path.ptr);
        resetIfHdd(kind);
        return;
    }

    var set = archive.extractImages(disk_alloc, path) catch |err| {
        std.debug.print("!! could not open archive '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };

    var count: usize = 0;
    var only: ?[*:0]const u8 = null;
    for (set.images) |img| {
        if (img.kind != kind) continue;
        count += 1;
        only = img.path.ptr;
    }

    switch (count) {
        0 => {
            std.debug.print("!! archive has no {s} image: {s}\n", .{ @tagName(kind), path });
            set.deinit();
        },
        1 => {
            insertOne(kind, drv, only.?);
            resetIfHdd(kind);
            set.deinit();
        },
        else => {
            // Hand ownership of `set` to the modal; it frees it on choose/cancel.
            ds_set = set;
            ds_kind = kind;
            ds_target = drv;
            ds_reset_after = (kind == .hdd);
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
        return;
    }

    var set = archive.extractImages(disk_alloc, path) catch |err| {
        std.debug.print("!! could not open archive '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer set.deinit();

    var slot: u32 = 0;
    for (set.images) |img| {
        if (img.kind != .fdd) continue;
        if (slot >= 2) {
            std.debug.print("!! ignoring extra fdd image (FDD1+2 holds 2): {s}\n", .{img.path});
            break;
        }
        insertOne(.fdd, slot, img.path.ptr);
        slot += 1;
    }
    if (slot == 0) std.debug.print("!! archive has no fdd image: {s}\n", .{path});
}

// --- Disk-selection modal (shown when an archive holds multiple images) ---

var ds_set: ?archive.ImageSet = null;
var ds_kind: cli.DiskKind = .fdd;
var ds_target: u32 = 0;
var ds_reset_after: bool = false;
var ds_reopen: bool = false;

fn ds_active() bool {
    return ds_set != null;
}

fn ds_clear() void {
    if (ds_set) |*s| s.deinit();
    ds_set = null;
}

fn drawDiskSelect(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const set = if (ds_set) |*s| s else return;

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

    var chosen: ?[*:0]const u8 = null;
    var cancel = false;
    if (c.nk_begin(ctx, "Select Disk", bounds, flags) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, "Choose a disk to mount:", c.NK_TEXT_LEFT);

        c.nk_layout_row_dynamic(ctx, 200, 1);
        if (c.nk_group_begin(ctx, "ds_list", c.NK_WINDOW_BORDER) != 0) {
            c.nk_layout_row_dynamic(ctx, 26, 1);
            for (set.images) |img| {
                if (img.kind != ds_kind) continue;
                if (c.nk_button_label(ctx, img.name.ptr) != 0) chosen = img.path.ptr;
            }
            c.nk_group_end(ctx);
        }

        c.nk_layout_row_dynamic(ctx, 26, 1);
        if (c.nk_button_label(ctx, "Cancel") != 0) cancel = true;
    }
    c.nk_end(ctx);
    if (c.nk_window_is_hidden(ctx, "Select Disk") != 0) cancel = true;

    if (chosen) |path| {
        insertOne(ds_kind, ds_target, path);
        if (ds_reset_after) cz.pccore_reset();
        ds_clear();
    } else if (cancel) {
        ds_clear();
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
