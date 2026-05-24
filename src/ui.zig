const std = @import("std");
const sokol = @import("sokol");
const sdtx = sokol.debugtext;
const sgl = sokol.gl;
const sapp = sokol.app;
const cz = @import("c.zig");
const nfd = @import("nfd.zig");

const sg = sokol.gfx;

const app_icon_raw = @embedFile("AppIcon128.raw");
var app_icon_view: sg.View = .{};
var app_icon_sampler: sg.Sampler = .{};
var app_icon_valid: bool = false;
var alpha_pipeline: sgl.Pipeline = .{};

pub const MENU_HEIGHT: u32 = 20;
pub const STATUS_HEIGHT: u32 = 20;

const CHAR_W: f32 = 8.0;
const CHAR_H: f32 = 8.0;
const MENU_LABEL_PAD: u32 = 8; // horizontal padding around each menu label

pub const State = struct {
    fps: f32 = 0.0,
    cpu_mhz: f32 = 0.0,
    fdd_access: [4]bool = .{ false, false, false, false },
    model: []const u8 = "",
};

const Menu = struct {
    label: []const u8,
    items: []const []const u8,
};

const menus = [_]Menu{
    .{
        .label = "File",
        .items = &.{
            "Open FDD1...", "Open FDD2...", "Eject FDD1", "Eject FDD2",
            "Open HDD1...", "Open HDD2...", "Eject HDD1", "Eject HDD2",
            "Quit",
        },
    },
    .{
        .label = "System",
        .items = &.{ "Reset", "System Setup", "Pause" },
    },
    .{
        .label = "Help",
        .items = &.{"About"},
    },
};

const disk_filters = [_]nfd.Filter{
    .{ .name = "All Disk Images", .spec = "fdi,d88,hdm,hdi,fdd,xdf,2hd,2dd,nfd,thd,nhd,vhd,hdd" },
};

const DROPDOWN_ITEM_H: u32 = 14;
const DROPDOWN_PAD_X: u32 = 8;
const DROPDOWN_MIN_W: u32 = 120;

// Status bar column layout (in pixel coordinates / character cells, 8px = 1 cell).
const STATUS_MODEL_CELL: f32 = 1.0; // px 8
const STATUS_FDD_LABEL_CELL: f32 = 22.0; // px 176, "FDD:" (4 chars)
const STATUS_FDD_LAMP_X: u32 = 216; // px just after "FDD:" label
const STATUS_LAMP_W: u32 = 12;
const STATUS_LAMP_H: u32 = 8;
const STATUS_LAMP_GAP: u32 = 4;
const STATUS_FPS_TAIL_CHARS: f32 = 9.0; // "120.0 FPS"

// Open menu index (-1 = none). Hover item index within the open dropdown (-1 = none).
var open_menu: i32 = -1;
var hover_item: i32 = -1;
var mouse_x: i32 = 0;
var mouse_y: i32 = 0;
var show_about: bool = false;

pub fn setup() void {
    sgl.setup(.{
        .logger = .{ .func = sokol.log.func },
    });

    var desc: sdtx.Desc = .{
        .logger = .{ .func = sokol.log.func },
    };
    desc.fonts[0] = sdtx.fontKc853();
    sdtx.setup(desc);

    // Alpha-blend pipeline for overlay / icon
    alpha_pipeline = sgl.makePipeline(.{
        .colors = init: {
            var colors: [8]sg.ColorTargetState = @splat(.{});
            colors[0] = .{
                .blend = .{
                    .enabled = true,
                    .src_factor_rgb = .SRC_ALPHA,
                    .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                },
            };
            break :init colors;
        },
    });

    // Load AppIcon128.raw (128x128 RGBA)
    var img_desc: sg.ImageDesc = .{
        .width = 128,
        .height = 128,
        .pixel_format = .RGBA8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = app_icon_raw.ptr,
        .size = app_icon_raw.len,
    };
    const app_icon_image = sg.makeImage(img_desc);

    app_icon_view = sg.makeView(.{
        .texture = .{ .image = app_icon_image },
    });

    app_icon_sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
    });

    app_icon_valid = true;
}

pub fn shutdown() void {
    sdtx.shutdown();
    sgl.shutdown();
}

/// Width in pixels of a menu label including padding.
fn menuLabelWidth(label: []const u8) u32 {
    return @as(u32, @intCast(label.len)) * 8 + MENU_LABEL_PAD * 2;
}

/// X position of menu label `i` (in pixels).
fn menuLabelX(i: usize) u32 {
    var x: u32 = 0;
    for (menus[0..i]) |m| x += menuLabelWidth(m.label);
    return x;
}

fn dropdownWidth(menu_idx: usize) u32 {
    var max_chars: usize = 0;
    for (menus[menu_idx].items) |it| {
        if (it.len > max_chars) max_chars = it.len;
    }
    const w: u32 = @as(u32, @intCast(max_chars)) * 8 + DROPDOWN_PAD_X * 2;
    return @max(w, DROPDOWN_MIN_W);
}

/// Returns `true` if (x,y) hits menu label `i`.
fn hitMenuLabel(i: usize, x: i32, y: i32) bool {
    if (y < 0 or y >= @as(i32, @intCast(MENU_HEIGHT))) return false;
    const lx: i32 = @intCast(menuLabelX(i));
    const lw: i32 = @intCast(menuLabelWidth(menus[i].label));
    return x >= lx and x < lx + lw;
}

/// If a dropdown is open and (x,y) is inside it, returns the item index. Else -1.
fn hitDropdownItem(x: i32, y: i32) i32 {
    if (open_menu < 0) return -1;
    const mi: usize = @intCast(open_menu);
    const dx: i32 = @intCast(menuLabelX(mi));
    const dw: i32 = @intCast(dropdownWidth(mi));
    const dy: i32 = @intCast(MENU_HEIGHT);
    const dh: i32 = @intCast(@as(u32, @intCast(menus[mi].items.len)) * DROPDOWN_ITEM_H);
    if (x < dx or x >= dx + dw or y < dy or y >= dy + dh) return -1;
    return @divFloor(y - dy, @as(i32, @intCast(DROPDOWN_ITEM_H)));
}

/// Returns `true` if the event was consumed by the menu.
pub fn handleMouseMove(x: i32, y: i32) bool {
    mouse_x = x;
    mouse_y = y;
    if (show_about) return true;
    if (open_menu < 0) return y < @as(i32, @intCast(MENU_HEIGHT));
    hover_item = hitDropdownItem(x, y);
    return true;
}

/// Returns `true` if the event was consumed.
pub fn handleMouseDown(x: i32, y: i32) bool {
    if (show_about) {
        show_about = false;
        return true;
    }
    // Click on a menu label: toggle / switch.
    for (menus, 0..) |_, i| {
        if (hitMenuLabel(i, x, y)) {
            const idx: i32 = @intCast(i);
            open_menu = if (open_menu == idx) -1 else idx;
            hover_item = -1;
            return true;
        }
    }
    // Click on a dropdown item: dispatch and close.
    const item = hitDropdownItem(x, y);
    if (item >= 0) {
        const mi: usize = @intCast(open_menu);
        dispatch(mi, @intCast(item));
        open_menu = -1;
        hover_item = -1;
        return true;
    }
    // Click outside an open menu: close it (and consume to avoid passing through).
    if (open_menu >= 0) {
        open_menu = -1;
        hover_item = -1;
        return true;
    }
    return false;
}

/// Returns `true` if Escape closed an open menu.
pub fn handleEscape() bool {
    if (show_about) {
        show_about = false;
        return true;
    }
    if (open_menu < 0) return false;
    open_menu = -1;
    hover_item = -1;
    return true;
}

fn dispatch(menu_idx: usize, item_idx: usize) void {
    switch (menu_idx) {
        0 => switch (item_idx) { // File
            0 => openFdd(0),
            1 => openFdd(1),
            2 => ejectFdd(0),
            3 => ejectFdd(1),
            4 => openHdd(0),
            5 => openHdd(1),
            6 => ejectHdd(0),
            7 => ejectHdd(1),
            8 => sapp.requestQuit(),
            else => {},
        },
        1 => switch (item_idx) { // System
            0 => {
                std.debug.print(">>> System reset\n", .{});
                cz.pccore_reset();
            },
            1 => {
                std.debug.print(">>> System setup (HELP+reset)\n", .{});
                cz.usa_reset_with_help();
            },
            2 => std.debug.print(">>> Pause (not implemented)\n", .{}),
            else => {},
        },
        2 => switch (item_idx) { // Help
            0 => show_about = true,
            else => {},
        },
        else => {},
    }
}

fn openFdd(drv: u32) void {
    if (pickDisk()) |path| {
        defer std.heap.page_allocator.free(path);
        std.debug.print(">>> FDD{d}: {s}\n", .{ drv, path });
        cz.np2_insert_fdd(drv, path.ptr);
    }
}

fn openHdd(drv: u32) void {
    if (pickDisk()) |path| {
        defer std.heap.page_allocator.free(path);
        std.debug.print(">>> HDD{d}: {s}\n", .{ drv, path });
        cz.np2_insert_hdd(drv, path.ptr);
    }
}

fn pickDisk() ?[:0]u8 {
    const result = nfd.openDialog(std.heap.page_allocator, &disk_filters) catch |err| {
        std.debug.print("!! NFD error: {s}\n", .{@errorName(err)});
        return null;
    };
    return result;
}

fn ejectFdd(drv: u32) void {
    cz.np2_eject_fdd(drv);
    std.debug.print(">>> Ejected FDD{d}\n", .{drv + 1});
}

fn ejectHdd(drv: u32) void {
    cz.np2_eject_hdd(drv);
    std.debug.print(">>> Ejected HDD{d}\n", .{drv + 1});
}

pub fn draw(win_w: u32, win_h: u32, st: State) void {
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    sgl.ortho(0.0, @floatFromInt(win_w), @floatFromInt(win_h), 0.0, -1.0, 1.0);

    // 1. Menu bar background
    rectFill(0, 0, win_w, MENU_HEIGHT, 0x30, 0x30, 0x38);

    // 2. Status bar background
    const status_y = win_h - STATUS_HEIGHT;
    rectFill(0, status_y, win_w, STATUS_HEIGHT, 0x18, 0x18, 0x20);

    // 3. FD access lamps
    const lamp_start_x: u32 = STATUS_FDD_LAMP_X;
    const lamp_y = status_y + (STATUS_HEIGHT - STATUS_LAMP_H) / 2;
    for (0..4) |i| {
        const lx = lamp_start_x + @as(u32, @intCast(i)) * (STATUS_LAMP_W + STATUS_LAMP_GAP);
        if (st.fdd_access[i]) {
            rectFill(lx, lamp_y, STATUS_LAMP_W, STATUS_LAMP_H, 0xFF, 0x60, 0x10); // active
        } else {
            rectFill(lx, lamp_y, STATUS_LAMP_W, STATUS_LAMP_H, 0x40, 0x18, 0x08); // dim
        }
    }

    // 4. Highlight open menu
    if (open_menu >= 0) {
        const mi: usize = @intCast(open_menu);
        rectFill(menuLabelX(mi), 0, menuLabelWidth(menus[mi].label), MENU_HEIGHT, 0x50, 0x50, 0x80);

        const dx = menuLabelX(mi);
        const dw = dropdownWidth(mi);
        const dh: u32 = @as(u32, @intCast(menus[mi].items.len)) * DROPDOWN_ITEM_H;
        rectFill(dx, MENU_HEIGHT, dw, dh, 0x28, 0x28, 0x30);

        if (hover_item >= 0) {
            const hy = MENU_HEIGHT + @as(u32, @intCast(hover_item)) * DROPDOWN_ITEM_H;
            rectFill(dx, hy, dw, DROPDOWN_ITEM_H, 0x50, 0x50, 0x80);
        }
    }

    // 5. About dialog
    if (show_about) {
        sgl.pushPipeline();
        sgl.loadPipeline(alpha_pipeline);

        // Overlay (semi-transparent)
        rectFillAlpha(0, 0, win_w, win_h, 0, 0, 0, 0.5);

        // Dialog box (OPAQUE)
        const dw: u32 = 360;
        const dh: u32 = 180;
        const dx = (win_w - dw) / 2;
        const dy = (win_h - dh) / 2;
        rectFill(dx, dy, dw, dh, 0x20, 0x20, 0x28);

        // Icon
        if (app_icon_valid) {
            sgl.enableTexture();
            sgl.texture(app_icon_view, app_icon_sampler);
            sgl.beginQuads();
            sgl.c4b(0xFF, 0xFF, 0xFF, 255);
            const ix = @as(f32, @floatFromInt(dx)) + 20.0;
            const iy = @as(f32, @floatFromInt(dy)) + 40.0;
            const iw = 64.0;
            const ih = 64.0;
            sgl.v2fT2f(ix, iy, 0.0, 0.0);
            sgl.v2fT2f(ix + iw, iy, 1.0, 0.0);
            sgl.v2fT2f(ix + iw, iy + ih, 1.0, 1.0);
            sgl.v2fT2f(ix, iy + ih, 0.0, 1.0);
            sgl.end();
            sgl.disableTexture();
        }

        // Border
        rectLine(dx, dy, dw, dh, 0x60, 0x60, 0x70);

        sgl.popPipeline();
    }

    drawText(win_w, win_h, st);
}

fn rectFill(x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8) void {
    sgl.beginQuads();
    sgl.c4b(r, g, b, 255); // Always opaque
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    sgl.v2f(fx, fy);
    sgl.v2f(fx + fw, fy);
    sgl.v2f(fx + fw, fy + fh);
    sgl.v2f(fx, fy + fh);
    sgl.end();
}

fn rectFillAlpha(x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8, a: f32) void {
    sgl.beginQuads();
    sgl.c4f(@as(f32, @floatFromInt(r)) / 255.0, @as(f32, @floatFromInt(g)) / 255.0, @as(f32, @floatFromInt(b)) / 255.0, a);
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    sgl.v2f(fx, fy);
    sgl.v2f(fx + fw, fy);
    sgl.v2f(fx + fw, fy + fh);
    sgl.v2f(fx, fy + fh);
    sgl.end();
}

fn rectLine(x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    sgl.beginLines();
    sgl.c4b(r, g, b, 255);
    sgl.v2f(fx, fy);
    sgl.v2f(fx + fw, fy);
    sgl.v2f(fx + fw, fy);
    sgl.v2f(fx + fw, fy + fh);
    sgl.v2f(fx + fw, fy + fh);
    sgl.v2f(fx, fy + fh);
    sgl.v2f(fx, fy + fh);
    sgl.v2f(fx, fy);
    sgl.end();
}

fn drawText(win_w: u32, win_h: u32, st: State) void {
    sdtx.canvas(@floatFromInt(win_w), @floatFromInt(win_h));
    sdtx.font(0);

    // Menu labels.
    sdtx.color3b(0xE0, 0xE0, 0xE0);
    for (menus, 0..) |m, i| {
        const x_cell: f32 = @as(f32, @floatFromInt(menuLabelX(i) + MENU_LABEL_PAD)) / CHAR_W;
        sdtx.pos(x_cell, (@as(f32, @floatFromInt(MENU_HEIGHT)) - CHAR_H) * 0.5 / CHAR_H);
        var lbuf: [16]u8 = undefined;
        const ll = std.fmt.bufPrintZ(&lbuf, "{s}", .{m.label}) catch continue;
        sdtx.puts(ll);
    }

    // Dropdown items.
    if (open_menu >= 0) {
        const mi: usize = @intCast(open_menu);
        const dx = menuLabelX(mi);
        for (menus[mi].items, 0..) |item, ii| {
            const ix_cell: f32 = @as(f32, @floatFromInt(dx + DROPDOWN_PAD_X)) / CHAR_W;
            const iy_px = MENU_HEIGHT + @as(u32, @intCast(ii)) * DROPDOWN_ITEM_H + (DROPDOWN_ITEM_H - @as(u32, @intFromFloat(CHAR_H))) / 2;
            const iy_cell: f32 = @as(f32, @floatFromInt(iy_px)) / CHAR_H;
            sdtx.color3b(0xE0, 0xE0, 0xE0);
            sdtx.pos(ix_cell, iy_cell);
            var ibuf: [32]u8 = undefined;
            const il = std.fmt.bufPrintZ(&ibuf, "{s}", .{item}) catch continue;
            sdtx.puts(il);
        }
    }

    // Status bar text. Layout (left → right): Model, CPU MHz, "FDD:" + lamps, gap, FPS.
    const status_y_px = win_h - STATUS_HEIGHT + (STATUS_HEIGHT - @as(u32, @intFromFloat(CHAR_H))) / 2;
    const status_y_cell = @as(f32, @floatFromInt(status_y_px)) / CHAR_H;

    sdtx.color3b(0xD0, 0xD0, 0xD0);

    // Model name.
    sdtx.pos(STATUS_MODEL_CELL, status_y_cell);
    var mbuf: [16]u8 = undefined;
    const mline = std.fmt.bufPrintZ(&mbuf, "{s}", .{st.model}) catch "?";
    sdtx.puts(mline);

    // CPU clock — placed immediately after the model name with a 2-cell gap so
    // the column tracks the model length instead of leaving a wide blank.
    const cpu_cell = STATUS_MODEL_CELL + @as(f32, @floatFromInt(st.model.len)) + 2.0;
    sdtx.pos(cpu_cell, status_y_cell);
    var cbuf: [32]u8 = undefined;
    const cline = std.fmt.bufPrintZ(&cbuf, "{d:>5.1}MHz", .{st.cpu_mhz}) catch "?MHz";
    sdtx.puts(cline);

    // "FDD:" label; the four graphical lamps are drawn in drawBackgrounds.
    sdtx.pos(STATUS_FDD_LABEL_CELL, status_y_cell);
    sdtx.puts("FDD:");

    // FPS, right-aligned with one cell of right padding.
    const fps_x_cell = @as(f32, @floatFromInt(win_w)) / CHAR_W - STATUS_FPS_TAIL_CHARS - 1.0;
    sdtx.pos(fps_x_cell, status_y_cell);
    var fbuf: [16]u8 = undefined;
    const fline = std.fmt.bufPrintZ(&fbuf, "{d:>5.1} FPS", .{st.fps}) catch "? FPS";
    sdtx.puts(fline);

    if (show_about) {
        const dw: f32 = 360.0;
        const dh: f32 = 180.0;
        const dx_cell = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0 / CHAR_W;
        const dy_cell = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0 / CHAR_H;

        // --- Text Content ---
        const tx_cell = dx_cell + 12;
        sdtx.color3b(0xFF, 0xFF, 0xFF);
        sdtx.pos(tx_cell, dy_cell + 4);
        sdtx.puts("UsaProject");

        sdtx.color3b(0xB0, 0xB0, 0xB0);
        sdtx.pos(tx_cell, dy_cell + 6);
        sdtx.puts("Version: 0.1.0");

        sdtx.pos(tx_cell, dy_cell + 9);
        sdtx.puts("Core: NP2kai");

        sdtx.pos(tx_cell, dy_cell + 10);
        sdtx.puts("Core Version: 0.86");
    }
}

test "UI state: menu and about dialog" {
    // Dummy implementations for linker
    const test_dummies = struct {
        export fn pccore_reset() void {}
        export fn usa_reset_with_help() void {}
        export fn np2_insert_fdd(_: u32, _: [*c]const u8) void {}
        export fn np2_insert_hdd(_: u32, _: [*c]const u8) void {}
        export fn np2_eject_fdd(_: u32) void {}
        export fn np2_eject_hdd(_: u32) void {}
        export fn NFD_Init() c_int { return 1; } // NFD_OKAY
        export fn NFD_OpenDialogU8(_: [*c][*c]u8, _: ?*const anyopaque, _: u32, _: ?[*:0]const u8) c_int { return 2; } // NFD_CANCEL
        export fn NFD_FreePathU8(_: [*c]u8) void {}
        export fn NFD_Quit() void {}
    };
    _ = test_dummies;

    // Reset state for test
    open_menu = -1;
    show_about = false;
    hover_item = -1;

    // 1. Help menu click
    const help_x: i32 = @intCast(menuLabelX(2) + 4);
    const help_y: i32 = 10;
    _ = handleMouseDown(help_x, help_y);
    try std.testing.expectEqual(@as(i32, 2), open_menu);

    // 2. Click About item
    const about_y = @as(i32, @intCast(MENU_HEIGHT + 5));
    _ = handleMouseDown(help_x, about_y);
    try std.testing.expect(show_about);
    try std.testing.expectEqual(@as(i32, -1), open_menu);

    // 3. Mouse move during About
    _ = handleMouseMove(100, 100);
    try std.testing.expect(show_about); // Should still be true

    // 4. Click to close About
    _ = handleMouseDown(100, 100);
    try std.testing.expect(!show_about);

    // 5. Escape to close About
    show_about = true;
    _ = handleEscape();
    try std.testing.expect(!show_about);
}
