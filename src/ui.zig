const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const cz = @import("c.zig");
const nfd = @import("nfd.zig");
const nk = @import("nk.zig");
const c = nk.c;

pub const MENU_HEIGHT: u32 = 26;
pub const STATUS_HEIGHT: u32 = 22;

pub const State = struct {
    fps: f32 = 0.0,
    cpu_mhz: f32 = 0.0,
    fdd_access: [4]bool = .{ false, false, false, false },
    model: []const u8 = "",
};

const disk_filters = [_]nfd.Filter{
    .{ .name = "All Disk Images", .spec = "fdi,d88,hdm,hdi,fdd,xdf,2hd,2dd,nfd,thd,nhd,vhd,hdd" },
};

var show_about: bool = false;

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

pub fn draw(ctx: *c.nk_context, win_w: u32, win_h: u32, st: State) void {
    drawMenuBar(ctx, win_w);
    drawStatusBar(ctx, win_w, win_h, st);
    if (show_about) drawAbout(ctx, win_w, win_h);
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

fn drawMenuBar(ctx: *c.nk_context, win_w: u32) void {
    const w: f32 = @floatFromInt(win_w);
    const h: f32 = @floatFromInt(MENU_HEIGHT);
    const bounds = c.nk_rect(0, 0, w, h);

    c.nk_window_set_bounds(ctx, "MenuBar", bounds);
    if (c.nk_begin(ctx, "MenuBar", bounds, c.NK_WINDOW_NO_SCROLLBAR | c.NK_WINDOW_BACKGROUND) != 0) {
        c.nk_menubar_begin(ctx);
        c.nk_layout_row_begin(ctx, c.NK_STATIC, h - 8, 3);

        // File
        c.nk_layout_row_push(ctx, 45);
        if (c.nk_menu_begin_label(ctx, "File", c.NK_TEXT_LEFT, c.nk_vec2(180, 280)) != 0) {
            c.nk_layout_row_dynamic(ctx, 22, 1);
            if (c.nk_menu_item_label(ctx, "Open FDD1...", c.NK_TEXT_LEFT) != 0) { pending = .open_fdd0; }
            if (c.nk_menu_item_label(ctx, "Open FDD2...", c.NK_TEXT_LEFT) != 0) { pending = .open_fdd1; }
            if (c.nk_menu_item_label(ctx, "Eject FDD1", c.NK_TEXT_LEFT) != 0) ejectFdd(0);
            if (c.nk_menu_item_label(ctx, "Eject FDD2", c.NK_TEXT_LEFT) != 0) ejectFdd(1);
            if (c.nk_menu_item_label(ctx, "Open HDD1...", c.NK_TEXT_LEFT) != 0) { pending = .open_hdd0; }
            if (c.nk_menu_item_label(ctx, "Open HDD2...", c.NK_TEXT_LEFT) != 0) { pending = .open_hdd1; }
            if (c.nk_menu_item_label(ctx, "Eject HDD1", c.NK_TEXT_LEFT) != 0) ejectHdd(0);
            if (c.nk_menu_item_label(ctx, "Eject HDD2", c.NK_TEXT_LEFT) != 0) ejectHdd(1);
            if (c.nk_menu_item_label(ctx, "Quit", c.NK_TEXT_LEFT) != 0) sapp.requestQuit();
            c.nk_menu_end(ctx);
        }

        // System
        c.nk_layout_row_push(ctx, 60);
        if (c.nk_menu_begin_label(ctx, "System", c.NK_TEXT_LEFT, c.nk_vec2(160, 100)) != 0) {
            c.nk_layout_row_dynamic(ctx, 22, 1);
            if (c.nk_menu_item_label(ctx, "Reset", c.NK_TEXT_LEFT) != 0) {
                cz.pccore_reset();
            }
            if (c.nk_menu_item_label(ctx, "System Setup", c.NK_TEXT_LEFT) != 0) {
                cz.usa_reset_with_help();
            }
            c.nk_menu_end(ctx);
        }

        // Help
        c.nk_layout_row_push(ctx, 45);
        if (c.nk_menu_begin_label(ctx, "Help", c.NK_TEXT_LEFT, c.nk_vec2(120, 50)) != 0) {
            c.nk_layout_row_dynamic(ctx, 22, 1);
            if (c.nk_menu_item_label(ctx, "About", c.NK_TEXT_LEFT) != 0) show_about = true;
            c.nk_menu_end(ctx);
        }

        c.nk_layout_row_end(ctx);
        c.nk_menubar_end(ctx);
    }
    c.nk_end(ctx);
}

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

fn drawAbout(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 340;
    const dh: f32 = 155;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;

    if (c.nk_begin(ctx, "About UsaProject", c.nk_rect(dx, dy, dw, dh), c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        // Icon + text side by side
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

        c.nk_layout_row_dynamic(ctx, 28, 1);
        if (c.nk_button_label(ctx, "Close") != 0) show_about = false;
    }
    c.nk_end(ctx);
}

const disk_alloc = std.heap.page_allocator;

fn openFdd(drv: u32) void {
    if (pickDisk()) |path| {
        defer disk_alloc.free(path);
        std.debug.print(">>> FDD{d}: {s}\n", .{ drv, path });
        cz.np2_insert_fdd(drv, path.ptr);
    }
}

fn openHdd(drv: u32) void {
    if (pickDisk()) |path| {
        defer disk_alloc.free(path);
        std.debug.print(">>> HDD{d}: {s}\n", .{ drv, path });
        cz.np2_insert_hdd(drv, path.ptr);
    }
}

fn pickDisk() ?[:0]u8 {
    return nfd.openDialog(disk_alloc, &disk_filters) catch |err| {
        std.debug.print("!! NFD error: {s}\n", .{@errorName(err)});
        return null;
    };
}

fn ejectFdd(drv: u32) void {
    cz.np2_eject_fdd(drv);
    std.debug.print(">>> Ejected FDD{d}\n", .{drv + 1});
}

fn ejectHdd(drv: u32) void {
    cz.np2_eject_hdd(drv);
    std.debug.print(">>> Ejected HDD{d}\n", .{drv + 1});
}
