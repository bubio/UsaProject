const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const cz = @import("c.zig");
const nfd = @import("nfd.zig");
const nk = @import("nk.zig");
const c = nk.c;
const ui_dialog = @import("ui_dialog.zig");

pub const MENU_HEIGHT: u32 = 26;
pub const STATUS_HEIGHT: u32 = 22;

pub const State = struct {
    fps: f32 = 0.0,
    cpu_mhz: f32 = 0.0,
    fdd_access: [4]bool = .{ false, false, false, false },
    model: []const u8 = "",
};

const fdd_filters = [_]nfd.Filter{
    .{ .name = "FDD Images", .spec = "fdi,d88,hdm,hdi,fdd,xdf,2hd,2dd,nfd" },
};
const hdd_filters = [_]nfd.Filter{
    .{ .name = "HDD Images", .spec = "thd,nhd,vhd,hdd,hdi" },
};

var show_about: bool = false;
var show_clock: bool = false;
var show_fps: bool = true;

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
        c.nk_layout_row_begin(ctx, c.NK_STATIC, h - 8, 6);

        menuEmulate(ctx);
        menuFdd(ctx);
        menuHdd(ctx);
        menuScreen(ctx, h);
        menuDevice(ctx, h);
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

fn menuScreen(ctx: *c.nk_context, menu_h: f32) void {
    _ = menu_h;
    c.nk_layout_row_push(ctx, 60);
    if (c.nk_menu_begin_label(ctx, "Screen", c.NK_TEXT_LEFT, c.nk_vec2(200, 320)) != 0) {
        var buf: [64]u8 = undefined;
        c.nk_layout_row_dynamic(ctx, 22, 1);

        if (c.nk_menu_item_label(ctx, "FullScreen", c.NK_TEXT_LEFT) != 0) {
            sapp.toggleFullscreen();
        }

        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);

        if (c.nk_menu_item_label(ctx, checkLabel(&buf, cz.c.np2cfg.DISPSYNC != 0, "Disp Vsync"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.DISPSYNC ^= 1;
        }
        if (c.nk_menu_item_label(ctx, checkLabel(&buf, cz.c.np2cfg.RASTER != 0, "Real Palettes"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.RASTER ^= 1;
        }
        if (c.nk_menu_item_label(ctx, checkLabel(&buf, cz.usa_get_nowait() != 0, "No Wait"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_nowait(cz.usa_get_nowait() ^ 1);
        }

        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);

        const skip = cz.usa_get_draw_skip();
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, skip == 0, "Auto frame"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_draw_skip(0);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, skip == 1, "Full frame"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_draw_skip(1);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, skip == 2, "1/2 frame"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_draw_skip(2);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, skip == 3, "1/3 frame"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_draw_skip(3);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, skip == 4, "1/4 frame"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_draw_skip(4);
        }

        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Screen option...", c.NK_TEXT_LEFT) != 0) {
            ui_dialog.openScreenOption();
        }

        c.nk_menu_end(ctx);
    }
}

fn menuDevice(ctx: *c.nk_context, menu_h: f32) void {
    _ = menu_h;
    c.nk_layout_row_push(ctx, 60);
    if (c.nk_menu_begin_label(ctx, "Device", c.NK_TEXT_LEFT, c.nk_vec2(240, 500)) != 0) {
        var buf: [64]u8 = undefined;

        // -- Keyboard --
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, "-- Keyboard --", c.NK_TEXT_LEFT);
        const kbd = cz.usa_get_keyboard();
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, kbd == 0, "JP Keyboard 106"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_keyboard(0);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, kbd != 0, "US Keyboard 101"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_set_keyboard(1);
        }

        // -- Beep --
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, "-- Beep --", c.NK_TEXT_LEFT);
        const beep = cz.c.np2cfg.BEEP_VOL;
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, beep == 0, "off"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_beep_setvol(0);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, beep == 1, "low"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_beep_setvol(1);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, beep == 2, "mid"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_beep_setvol(2);
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, beep == 3, "high"), c.NK_TEXT_LEFT) != 0) {
            cz.usa_beep_setvol(3);
        }

        // -- Sound Board --
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, "-- Sound Board --", c.NK_TEXT_LEFT);
        const snd = cz.c.np2cfg.SOUND_SW;
        const SndId = struct {
            const NONE: u8 = 0x00;
            const K26: u8 = 0x02;
            const K86: u8 = 0x04;
            const K86_26K: u8 = 0x06;
            const K86_ADPCM: u8 = 0x14;
            const K118: u8 = 0x08;
            const AMD98: u8 = 0x80;
        };
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.NONE, "Disable boards"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.NONE;
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.K26, "PC-9801-26K"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.K26;
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.K86, "PC-9801-86"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.K86;
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.K86_26K, "PC-9801-26K + 86"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.K86_26K;
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.K86_ADPCM, "PC-9801-86 + Chibi-oto"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.K86_ADPCM;
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.K118, "PC-9801-118"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.K118;
        }
        if (c.nk_menu_item_label(ctx, radioLabel(&buf, snd == SndId.AMD98, "AMD-98"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.SOUND_SW = SndId.AMD98;
        }

        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, checkLabel(&buf, cz.c.np2cfg.MOTOR != 0, "Seek Sound"), c.NK_TEXT_LEFT) != 0) {
            cz.c.np2cfg.MOTOR ^= 1;
        }

        // -- Memory --
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, "-- Memory --", c.NK_TEXT_LEFT);
        const ext = cz.c.np2cfg.EXTMEM;
        const MemEntry = struct { val: u16, label: []const u8 };
        const mem_entries = [_]MemEntry{
            .{ .val = 0, .label = "640KB" },
            .{ .val = 1, .label = "1.6MB" },
            .{ .val = 3, .label = "3.6MB" },
            .{ .val = 7, .label = "7.6MB" },
            .{ .val = 13, .label = "13.6MB" },
        };
        for (mem_entries) |entry| {
            if (c.nk_menu_item_label(ctx, radioLabel(&buf, ext == entry.val, entry.label), c.NK_TEXT_LEFT) != 0) {
                cz.c.np2cfg.EXTMEM = entry.val;
            }
        }

        // -- Sound option --
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "Sound option...", c.NK_TEXT_LEFT) != 0) {
            ui_dialog.openSoundMixer();
        }

        c.nk_menu_end(ctx);
    }
}

fn menuOther(ctx: *c.nk_context) void {
    var buf: [64]u8 = undefined;
    c.nk_layout_row_push(ctx, 50);
    if (c.nk_menu_begin_label(ctx, "Other", c.NK_TEXT_LEFT, c.nk_vec2(160, 120)) != 0) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, checkLabel(&buf, show_clock, "Clock Disp"), c.NK_TEXT_LEFT) != 0) {
            show_clock = !show_clock;
        }
        if (c.nk_menu_item_label(ctx, checkLabel(&buf, show_fps, "Frame Disp"), c.NK_TEXT_LEFT) != 0) {
            show_fps = !show_fps;
        }
        c.nk_layout_row_dynamic(ctx, 4, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        if (c.nk_menu_item_label(ctx, "About...", c.NK_TEXT_LEFT) != 0) show_about = true;
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

        if (show_fps) {
            var fbuf: [16]u8 = undefined;
            const fline = std.fmt.bufPrintZ(&fbuf, "{d:.1} FPS", .{st.fps}) catch "? FPS";
            c.nk_label(ctx, fline.ptr, c.NK_TEXT_RIGHT);
        } else {
            c.nk_spacing(ctx, 1);
        }
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
    const dh: f32 = 155;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;

    if (c.nk_begin(ctx, "About UsaProject", c.nk_rect(dx, dy, dw, dh), c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_NO_SCROLLBAR) != 0) {
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
    }
}

fn ejectFdd(drv: u32) void {
    cz.np2_eject_fdd(drv);
}

fn ejectHdd(drv: u32) void {
    cz.np2_eject_hdd(drv);
}
