const std = @import("std");
const cz = @import("c.zig");
const nk = @import("nk.zig");
const input = @import("input.zig");
const c = nk.c;

const dialog_flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_CLOSABLE | c.NK_WINDOW_NO_SCROLLBAR;
const box_flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_NO_SCROLLBAR;

// --- Visibility & reopen flags ---

var show_configure: bool = false;
pub var show_about: bool = false;

var reopen_configure: bool = false;
pub var reopen_about: bool = false;

// Active tab in the unified Configure dialog (0=System, 1=Screen, 2=Sound).
var active_tab: u8 = 0;

fn closeAll() void {
    show_configure = false;
    show_about = false;
}

pub fn openConfigure() void {
    closeAll();
    show_configure = true;
    reopen_configure = true;
    cfg_initial = captureConfigState();
}

pub fn openAbout() void {
    closeAll();
    show_about = true;
    reopen_about = true;
}

pub fn draw(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    drawConfigure(ctx, win_w, win_h);
}

fn prepareDialog(ctx: *c.nk_context, name: [*:0]const u8, bounds: c.struct_nk_rect, reopen: *bool) void {
    c.nk_window_show(ctx, name, c.NK_SHOWN);
    if (reopen.*) {
        reopen.* = false;
        c.nk_window_set_bounds(ctx, name, bounds);
    }
}

fn handleClose(ctx: *c.nk_context, name: [*:0]const u8, show: *bool) bool {
    if (c.nk_window_is_hidden(ctx, name) != 0) {
        show.* = false;
        return true;
    }
    return false;
}

// A titled, bordered group box used to classify a section inside a tab.
// Allocates a fixed-height row then begins the group; returns true if visible.
fn beginBox(ctx: *c.nk_context, id: [*:0]const u8, title: [*:0]const u8, h: f32) bool {
    c.nk_layout_row_dynamic(ctx, h, 1);
    return c.nk_group_begin_titled(ctx, id, title, box_flags) != 0;
}

// ========================================================================
// Configure — unified tabbed dialog (System / Screen / Sound)
// ========================================================================

// Only the fields that require a core reset are tracked. Screen / Sound-mixer /
// device toggles apply immediately and do not need a reset.
const ConfigState = struct {
    baseclock: u32,
    multiple: u32,
    model: [8]u8,
    samplingrate: u32,
    delayms: u16,
    sound_sw: u8,
    extmem: u16,

    fn eql(a: ConfigState, b: ConfigState) bool {
        return a.baseclock == b.baseclock and a.multiple == b.multiple and
            std.mem.eql(u8, &a.model, &b.model) and
            a.samplingrate == b.samplingrate and a.delayms == b.delayms and
            a.sound_sw == b.sound_sw and a.extmem == b.extmem;
    }
};

var cfg_initial: ConfigState = undefined;

fn captureConfigState() ConfigState {
    return .{
        .baseclock = cz.c.np2cfg.baseclock,
        .multiple = cz.c.np2cfg.multiple,
        .model = cz.c.np2cfg.model,
        .samplingrate = cz.c.np2cfg.samplingrate,
        .delayms = cz.c.np2cfg.delayms,
        .sound_sw = cz.c.np2cfg.SOUND_SW,
        .extmem = cz.c.np2cfg.EXTMEM,
    };
}

fn modelToIdx(model: [8]u8) usize {
    if (model[0] == 'V' and model[1] == 'X') return 1;
    if (model[0] == 'V' and model[1] == 'M') return 0;
    return 2;
}

const base_clocks = [_]u32{ 1996800, 2457600 };
const base_clock_labels = [_][*:0]const u8{ "1.9968 MHz", "2.4576 MHz" };
const multipliers = [_]u32{ 1, 2, 4, 5, 6, 8, 10, 12, 16, 20 };
const model_labels = [_][*:0]const u8{ "PC-9801VM", "PC-9801VX", "PC-286" };
const model_names = [_][*:0]const u8{ "VM", "VX", "PC286" };
const sample_rates = [_]u32{ 22050, 44100, 48000 };
const sample_rate_labels = [_][*:0]const u8{ "22050", "44100", "48000" };

const snd_board_vals = [_]u8{ 0x00, 0x02, 0x04, 0x06, 0x14, 0x08, 0x80 };
const snd_board_labels = [_][*:0]const u8{
    "Disable",      "PC-9801-26K",  "PC-9801-86",
    "26K + 86",     "86 + Chibi-oto", "PC-9801-118", "AMD-98",
};
const mem_vals = [_]u16{ 0, 1, 3, 7, 13, 16, 32, 64, 128 };
const mem_labels_arr = [_][*:0]const u8{ "640KB", "1.6MB", "3.6MB", "7.6MB", "13.6MB", "16.6MB", "32.6MB", "64.6MB", "128.6MB" };

const skip_labels = [_][*:0]const u8{ "Auto", "Full", "1/2", "1/3", "1/4" };
const beep_labels = [_][*:0]const u8{ "Mute", "Low", "Mid", "High" };

const tab_labels = [_][*:0]const u8{ "System", "Screen", "Sound" };

const multipliers_labels = blk: {
    var labels: [multipliers.len][*:0]const u8 = undefined;
    for (multipliers, 0..) |m, i| {
        labels[i] = std.fmt.comptimePrint("{d}", .{m});
    }
    break :blk labels;
};

fn drawConfigure(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    if (!show_configure) return;

    const dw: f32 = 340;
    const dh: f32 = 400;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const cfg = &cz.c.np2cfg;

    prepareDialog(ctx, "Configure", bounds, &reopen_configure);

    if (c.nk_begin(ctx, "Configure", bounds, dialog_flags) != 0) {
        // --- Tab bar ---
        const active_col = c.nk_style_item_color(c.nk_rgb(70, 110, 160));
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 26, tab_labels.len);
        for (tab_labels, 0..) |name, i| {
            const is_active = @as(usize, active_tab) == i;
            c.nk_layout_row_push(ctx, 96);
            if (is_active) _ = c.nk_style_push_style_item(ctx, &ctx.style.button.normal, active_col);
            if (c.nk_button_label(ctx, name) != 0) active_tab = @intCast(i);
            if (is_active) _ = c.nk_style_pop_style_item(ctx);
        }
        c.nk_layout_row_end(ctx);

        // --- Tab body (scrollable; section boxes nested inside) ---
        c.nk_layout_row_dynamic(ctx, dh - 80, 1);
        if (c.nk_group_begin(ctx, "cfg_body", 0) != 0) {
            switch (active_tab) {
                0 => drawSystemTab(ctx, cfg),
                1 => drawScreenTab(ctx, cfg),
                else => drawSoundTab(ctx, cfg),
            }
            c.nk_group_end(ctx);
        }
    }
    c.nk_end(ctx);

    if (handleClose(ctx, "Configure", &show_configure)) {
        if (!cfg_initial.eql(captureConfigState())) {
            cz.pccore_reset();
        }
    }
}

// --- Tab 1: System (CPU / Architecture / Memory / Keyboard) ---

fn drawSystemTab(ctx: *c.nk_context, cfg: anytype) void {
    if (beginBox(ctx, "sys_cpu", "CPU", 90)) {
        c.nk_layout_row_dynamic(ctx, 22, 2);
        for (base_clocks, 0..) |clk, i| {
            const was: c_int = if (cfg.baseclock == clk) 1 else 0;
            if (c.nk_option_label(ctx, base_clock_labels[i], was) != 0 and was == 0)
                cfg.baseclock = clk;
        }
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 70);
        c.nk_label(ctx, "Multiple:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 180);
        var mul_idx: usize = 0;
        for (multipliers, 0..) |m, i| {
            if (cfg.multiple == m) { mul_idx = i; break; }
        }
        const new_mul: usize = @intCast(c.nk_combo(ctx, &multipliers_labels,
            multipliers_labels.len, @intCast(mul_idx), 22, c.nk_vec2(180, 200)));
        cfg.multiple = multipliers[new_mul];
        c.nk_layout_row_end(ctx);
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "sys_arch", "Architecture", 58)) {
        c.nk_layout_row_dynamic(ctx, 22, 3);
        const cur_model = modelToIdx(cfg.model);
        for (model_labels, 0..) |lbl, i| {
            const was: c_int = if (cur_model == i) 1 else 0;
            if (c.nk_option_label(ctx, lbl, was) != 0 and was == 0)
                cz.np2_set_model(model_names[i]);
        }
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "sys_mem", "Memory", 58)) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var mem_idx: usize = 1;
        for (mem_vals, 0..) |v, i| {
            if (cfg.EXTMEM == v) { mem_idx = i; break; }
            if (v > cfg.EXTMEM) { mem_idx = if (i > 0) i - 1 else 0; break; }
        }
        const new_mem: usize = @intCast(c.nk_combo(ctx, &mem_labels_arr,
            mem_labels_arr.len, @intCast(mem_idx), 22, c.nk_vec2(200, 200)));
        cfg.EXTMEM = mem_vals[new_mem];
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "sys_kbd", "Keyboard", 58)) {
        c.nk_layout_row_dynamic(ctx, 22, 2);
        const kbd = cz.usa_get_keyboard();
        if (c.nk_option_label(ctx, "JP 106", if (kbd == 0) 1 else 0) != 0 and kbd != 0)
            cz.usa_set_keyboard(0);
        if (c.nk_option_label(ctx, "US 101", if (kbd != 0) 1 else 0) != 0 and kbd == 0)
            cz.usa_set_keyboard(1);
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "sys_mouse", "Mouse", 58)) {
        // Applies live; no core reset needed. 100% = per-OS default sensitivity.
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 3);
        c.nk_layout_row_push(ctx, 80);
        c.nk_label(ctx, "Sensitivity:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 150);
        var s_f: f32 = @floatFromInt(input.getSensitivity());
        s_f = c.nk_slide_float(ctx, @floatFromInt(input.sensi_min), s_f, @floatFromInt(input.sensi_max), 5);
        input.setSensitivity(@intFromFloat(s_f));
        c.nk_layout_row_push(ctx, 45);
        var sbuf: [8:0]u8 = undefined;
        const sstr = std.fmt.bufPrintZ(&sbuf, "{d}%", .{input.getSensitivity()}) catch "?";
        c.nk_label(ctx, sstr.ptr, c.NK_TEXT_RIGHT);
        c.nk_layout_row_end(ctx);
        c.nk_group_end(ctx);
    }

    c.nk_layout_row_dynamic(ctx, 16, 1);
    c.nk_label_colored(ctx, "* Auto-reset on close if changed", c.NK_TEXT_LEFT, c.nk_rgb(0xFF, 0x80, 0x40));
}

// --- Tab 2: Screen (display toggles / GDC / Graphic Charger / Skipline / Mono) ---

fn drawScreenTab(ctx: *c.nk_context, cfg: anytype) void {
    if (beginBox(ctx, "scr_disp", "Display", 108)) {
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var raster_v: c_int = if (cfg.RASTER != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Real Palettes", &raster_v);
        cfg.RASTER = if (raster_v != 0) 1 else 0;

        const nowait = cz.usa_get_nowait();
        var nowait_v: c_int = if (nowait != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "No Wait", &nowait_v);
        const nowait_new: u8 = if (nowait_v != 0) 1 else 0;
        if (nowait_new != nowait) cz.usa_set_nowait(nowait_new);

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 90);
        c.nk_label(ctx, "Frame skip:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 160);
        const cur_skip: usize = @intCast(cz.usa_get_draw_skip());
        const new_skip: usize = @intCast(c.nk_combo(ctx, &skip_labels,
            skip_labels.len, @intCast(cur_skip), 22, c.nk_vec2(160, 150)));
        if (new_skip != cur_skip) cz.usa_set_draw_skip(@intCast(new_skip));
        c.nk_layout_row_end(ctx);
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "scr_gdc", "GDC", 58)) {
        const prev_gdc = cfg.uPD72020;
        c.nk_layout_row_dynamic(ctx, 22, 2);
        const was0: c_int = if (cfg.uPD72020 == 0) 1 else 0;
        if (c.nk_option_label(ctx, "uPD7220", was0) != 0 and was0 == 0)
            cfg.uPD72020 = 0;
        const was1: c_int = if (cfg.uPD72020 != 0) 1 else 0;
        if (c.nk_option_label(ctx, "uPD72020", was1) != 0 and was1 == 0)
            cfg.uPD72020 = 1;
        if (cfg.uPD72020 != prev_gdc) {
            cz.usa_gdc_restorekacmode();
            cz.usa_gdc_alldraw2();
        }
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "scr_grcg", "Graphic Charger", 58)) {
        const prev_grcg = cfg.grcg;
        const prev_color16 = cfg.color16;
        c.nk_layout_row_dynamic(ctx, 22, 4);
        const gc_labels = [_][*:0]const u8{ "None", "GRCG", "GRCG+", "EGC" };
        const gc_grcg = [_]u8{ 0, 1, 1, 1 };
        const gc_color16 = [_]u8{ 0, 0, 1, 2 };
        var gc_idx: usize = 0;
        if (cfg.grcg != 0) {
            if (cfg.color16 == 0) gc_idx = 1
            else if (cfg.color16 == 1) gc_idx = 2
            else gc_idx = 3;
        }
        for (gc_labels, 0..) |lbl, i| {
            const was: c_int = if (gc_idx == i) 1 else 0;
            if (c.nk_option_label(ctx, lbl, was) != 0 and was == 0) {
                cfg.grcg = gc_grcg[i];
                cfg.color16 = gc_color16[i];
            }
        }
        if (cfg.grcg != prev_grcg or cfg.color16 != prev_color16) {
            cz.usa_gdc_alldraw2();
        }
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "scr_skip", "Skipline / Monochrome", 116)) {
        const prev_skipline = cfg.skipline;
        const prev_skiplight = cfg.skiplight;
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var skipline_v: c_int = if (cfg.skipline != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Skipline", &skipline_v);
        cfg.skipline = @intCast(@as(u32, @intCast(skipline_v)));

        if (cfg.skipline != 0) {
            c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
            c.nk_layout_row_push(ctx, 70);
            c.nk_label(ctx, "Brightness:", c.NK_TEXT_LEFT);
            c.nk_layout_row_push(ctx, 180);
            var sl_f: f32 = @floatFromInt(cfg.skiplight);
            sl_f = c.nk_slide_float(ctx, 0, sl_f, 255, 1);
            cfg.skiplight = @intFromFloat(sl_f);
            c.nk_layout_row_end(ctx);
        }
        if (cfg.skipline != prev_skipline or cfg.skiplight != prev_skiplight) {
            cz.usa_pal_makeskiptable();
            cz.scrndraw_redraw();
        }

        const prev_lcd = cfg.LCD_MODE;
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var lcd_v: c_int = if (cfg.LCD_MODE & 1 != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Monochrome (LCD)", &lcd_v);
        cfg.LCD_MODE = (cfg.LCD_MODE & 0xfe) | @as(u8, @intCast(@as(u32, @intCast(lcd_v)) & 1));
        if (cfg.LCD_MODE != prev_lcd) {
            cz.usa_pal_makelcdpal();
            cz.scrndraw_redraw();
        }
        c.nk_group_end(ctx);
    }
}

// --- Tab 3: Sound (board / sampling / buffer / beep / seek / mixer) ---

fn drawSoundTab(ctx: *c.nk_context, cfg: anytype) void {
    if (beginBox(ctx, "snd_dev", "Sound Device", 110)) {
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 95);
        c.nk_label(ctx, "Sound Board:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 190);
        var snd_idx: usize = 0;
        for (snd_board_vals, 0..) |v, i| {
            if (cfg.SOUND_SW == v) { snd_idx = i; break; }
        }
        const new_snd: usize = @intCast(c.nk_combo(ctx, &snd_board_labels,
            snd_board_labels.len, @intCast(snd_idx), 22, c.nk_vec2(190, 170)));
        cfg.SOUND_SW = snd_board_vals[new_snd];
        c.nk_layout_row_end(ctx);

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 95);
        c.nk_label(ctx, "Sampling rate:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 120);
        var sr_idx: usize = 1;
        for (sample_rates, 0..) |sr, i| {
            if (cfg.samplingrate == sr) { sr_idx = i; break; }
        }
        const new_sr: usize = @intCast(c.nk_combo(ctx, &sample_rate_labels,
            sample_rate_labels.len, @intCast(sr_idx), 22, c.nk_vec2(120, 90)));
        cfg.samplingrate = sample_rates[new_sr];
        c.nk_layout_row_end(ctx);

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 3);
        c.nk_layout_row_push(ctx, 95);
        c.nk_label(ctx, "Buffer (ms):", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 150);
        var delay_f: f32 = @floatFromInt(cfg.delayms);
        delay_f = c.nk_slide_float(ctx, 50, delay_f, 250, 10);
        cfg.delayms = @intFromFloat(delay_f);
        c.nk_layout_row_push(ctx, 35);
        var delay_buf: [8:0]u8 = undefined;
        const delay_str = std.fmt.bufPrintZ(&delay_buf, "{d}", .{cfg.delayms}) catch "?";
        c.nk_label(ctx, delay_str.ptr, c.NK_TEXT_RIGHT);
        c.nk_layout_row_end(ctx);
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "snd_beep", "Beep & Seek", 84)) {
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 95);
        c.nk_label(ctx, "Beep volume:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 120);
        const cur_beep: usize = @intCast(cfg.BEEP_VOL);
        const new_beep: usize = @intCast(c.nk_combo(ctx, &beep_labels,
            beep_labels.len, @intCast(cur_beep), 22, c.nk_vec2(120, 130)));
        if (new_beep != cur_beep) cz.usa_beep_setvol(@intCast(new_beep));
        c.nk_layout_row_end(ctx);

        c.nk_layout_row_dynamic(ctx, 22, 1);
        var motor_v: c_int = if (cfg.MOTOR != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Seek Sound", &motor_v);
        cfg.MOTOR = if (motor_v != 0) 1 else 0;
        c.nk_group_end(ctx);
    }

    if (beginBox(ctx, "snd_mix", "Mixer", 234)) {
        const SliderEntry = struct { label: [*:0]const u8, val: *u8 };
        var entries = [_]SliderEntry{
            .{ .label = "FM", .val = &cfg.vol_fm },
            .{ .label = "PSG", .val = &cfg.vol_ssg },
            .{ .label = "ADPCM", .val = &cfg.vol_adpcm },
            .{ .label = "PCM", .val = &cfg.vol_pcm },
            .{ .label = "Rhythm", .val = &cfg.vol_rhythm },
        };

        var changed = false;
        for (&entries) |*entry| {
            c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 3);
            c.nk_layout_row_push(ctx, 55);
            c.nk_label(ctx, entry.label, c.NK_TEXT_LEFT);
            c.nk_layout_row_push(ctx, 160);
            const before = entry.val.*;
            var f: f32 = @floatFromInt(before);
            f = c.nk_slide_float(ctx, 0, f, 128, 1);
            const after: u8 = @intFromFloat(f);
            if (after != before) {
                entry.val.* = after;
                changed = true;
            }
            c.nk_layout_row_push(ctx, 35);
            var vbuf: [8:0]u8 = undefined;
            const vstr = std.fmt.bufPrintZ(&vbuf, "{d}", .{entry.val.*}) catch "?";
            c.nk_label(ctx, vstr.ptr, c.NK_TEXT_RIGHT);
            c.nk_layout_row_end(ctx);
        }

        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 26, 1);
        if (c.nk_button_label(ctx, "Defaults") != 0) {
            cfg.vol_fm = 64;
            cfg.vol_ssg = 64;
            cfg.vol_adpcm = 64;
            cfg.vol_pcm = 64;
            cfg.vol_rhythm = 64;
            changed = true;
        }
        if (changed) cz.usa_sound_apply_volumes();
        c.nk_group_end(ctx);
    }
}
