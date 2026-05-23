const std = @import("std");
const sokol = @import("sokol");
const sdtx = sokol.debugtext;
const sgl = sokol.gl;
const sapp = sokol.app;
const cz = @import("c.zig");
const nfd = @import("nfd.zig");

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
        .items = &.{ "Reset", "Pause" },
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

pub fn setup() void {
    sgl.setup(.{
        .logger = .{ .func = sokol.log.func },
    });

    var desc: sdtx.Desc = .{
        .logger = .{ .func = sokol.log.func },
    };
    desc.fonts[0] = sdtx.fontKc853();
    sdtx.setup(desc);
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
    if (open_menu < 0) return y < @as(i32, @intCast(MENU_HEIGHT));
    hover_item = hitDropdownItem(x, y);
    return true;
}

/// Returns `true` if the event was consumed.
pub fn handleMouseDown(x: i32, y: i32) bool {
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
            1 => std.debug.print(">>> Pause (not implemented)\n", .{}),
            else => {},
        },
        2 => switch (item_idx) { // Help
            0 => std.debug.print(">>> UsaProject — PC-98 emulator (Zig + sokol + NP2kai)\n", .{}),
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
    drawBackgrounds(win_w, win_h, st);
    drawText(win_w, win_h, st);
}

fn drawBackgrounds(win_w: u32, win_h: u32, st: State) void {
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    // Top-left origin, y grows downward.
    sgl.ortho(0.0, @floatFromInt(win_w), @floatFromInt(win_h), 0.0, -1.0, 1.0);

    sgl.beginQuads();

    // Menu bar background.
    rectFill(0, 0, win_w, MENU_HEIGHT, 0x30, 0x30, 0x38);
    // Status bar background.
    const status_y = win_h - STATUS_HEIGHT;
    rectFill(0, status_y, win_w, STATUS_HEIGHT, 0x18, 0x18, 0x20);

    // FD access lamps (graphical), positioned to follow the "FDD:" label.
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

    // Highlight the open menu label.
    if (open_menu >= 0) {
        const mi: usize = @intCast(open_menu);
        rectFill(menuLabelX(mi), 0, menuLabelWidth(menus[mi].label), MENU_HEIGHT, 0x50, 0x50, 0x80);

        // Dropdown background + items.
        const dx = menuLabelX(mi);
        const dw = dropdownWidth(mi);
        const dh: u32 = @as(u32, @intCast(menus[mi].items.len)) * DROPDOWN_ITEM_H;
        rectFill(dx, MENU_HEIGHT, dw, dh, 0x28, 0x28, 0x30);

        if (hover_item >= 0) {
            const hy = MENU_HEIGHT + @as(u32, @intCast(hover_item)) * DROPDOWN_ITEM_H;
            rectFill(dx, hy, dw, DROPDOWN_ITEM_H, 0x50, 0x50, 0x80);
        }
    }

    sgl.end();
}

fn rectFill(x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    sgl.c3b(r, g, b);
    sgl.v2f(fx, fy);
    sgl.v2f(fx + fw, fy);
    sgl.v2f(fx + fw, fy + fh);
    sgl.v2f(fx, fy + fh);
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
}
