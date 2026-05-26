const std = @import("std");
const cz = @import("c.zig");
const nk = @import("nk.zig");
const c = nk.c;

const dialog_flags = c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_CLOSABLE | c.NK_WINDOW_NO_SCROLLBAR;

// --- Visibility & reopen flags ---

var show_configure: bool = false;
var show_screen_opt: bool = false;
var show_sound_mixer: bool = false;
pub var show_about: bool = false;

var reopen_configure: bool = false;
var reopen_screen_opt: bool = false;
var reopen_sound_mixer: bool = false;
pub var reopen_about: bool = false;

fn closeAll() void {
    show_configure = false;
    show_screen_opt = false;
    show_sound_mixer = false;
    show_about = false;
}

pub fn openConfigure() void {
    closeAll();
    show_configure = true;
    reopen_configure = true;
    cfg_initial = captureConfigState();
}

pub fn openScreenOption() void {
    closeAll();
    show_screen_opt = true;
    reopen_screen_opt = true;
}

pub fn openSoundMixer() void {
    closeAll();
    show_sound_mixer = true;
    reopen_sound_mixer = true;
}

pub fn openAbout() void {
    closeAll();
    show_about = true;
    reopen_about = true;
}

pub fn draw(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    drawConfigure(ctx, win_w, win_h);
    drawScreenOption(ctx, win_w, win_h);
    drawSoundMixer(ctx, win_w, win_h);
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

// ========================================================================
// Configure (CPU, Architecture, Sound Board, Memory, Sound)
// ========================================================================

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
const mem_vals = [_]u16{ 0, 1, 3, 7, 13 };
const mem_labels_arr = [_][*:0]const u8{ "640KB", "1.6MB", "3.6MB", "7.6MB", "13.6MB" };

const multipliers_labels = blk: {
    var labels: [multipliers.len][*:0]const u8 = undefined;
    for (multipliers, 0..) |m, i| {
        labels[i] = std.fmt.comptimePrint("{d}", .{m});
    }
    break :blk labels;
};

fn drawConfigure(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    if (!show_configure) return;

    const dw: f32 = 360;
    const dh: f32 = 350;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const cfg = &cz.c.np2cfg;

    prepareDialog(ctx, "Configure", bounds, &reopen_configure);

    if (c.nk_begin(ctx, "Configure", bounds, dialog_flags) != 0) {
        // --- CPU ---
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label(ctx, "CPU", c.NK_TEXT_LEFT);
        c.nk_layout_row_dynamic(ctx, 22, 2);
        for (base_clocks, 0..) |clk, i| {
            const was: c_int = if (cfg.baseclock == clk) 1 else 0;
            if (c.nk_option_label(ctx, base_clock_labels[i], was) != 0 and was == 0)
                cfg.baseclock = clk;
        }
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 80);
        c.nk_label(ctx, "Multiple:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 200);
        var mul_idx: usize = 0;
        for (multipliers, 0..) |m, i| {
            if (cfg.multiple == m) { mul_idx = i; break; }
        }
        const new_mul: usize = @intCast(c.nk_combo(ctx, &multipliers_labels,
            multipliers_labels.len, @intCast(mul_idx), 22, c.nk_vec2(200, 200)));
        cfg.multiple = multipliers[new_mul];
        c.nk_layout_row_end(ctx);

        // --- Architecture ---
        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label(ctx, "Architecture", c.NK_TEXT_LEFT);
        c.nk_layout_row_dynamic(ctx, 22, 3);
        const cur_model = modelToIdx(cfg.model);
        for (model_labels, 0..) |lbl, i| {
            const was: c_int = if (cur_model == i) 1 else 0;
            if (c.nk_option_label(ctx, lbl, was) != 0 and was == 0)
                cz.np2_set_model(model_names[i]);
        }

        // --- Sound Board (combo) ---
        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 110);
        c.nk_label(ctx, "Sound Board:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 200);
        var snd_idx: usize = 0;
        for (snd_board_vals, 0..) |v, i| {
            if (cfg.SOUND_SW == v) { snd_idx = i; break; }
        }
        const new_snd: usize = @intCast(c.nk_combo(ctx, &snd_board_labels,
            snd_board_labels.len, @intCast(snd_idx), 22, c.nk_vec2(200, 170)));
        cfg.SOUND_SW = snd_board_vals[new_snd];
        c.nk_layout_row_end(ctx);

        // --- Memory (combo) ---
        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 110);
        c.nk_label(ctx, "Memory:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 200);
        var mem_idx: usize = 0;
        for (mem_vals, 0..) |v, i| {
            if (cfg.EXTMEM == v) { mem_idx = i; break; }
        }
        const new_mem: usize = @intCast(c.nk_combo(ctx, &mem_labels_arr,
            mem_labels_arr.len, @intCast(mem_idx), 22, c.nk_vec2(200, 130)));
        cfg.EXTMEM = mem_vals[new_mem];
        c.nk_layout_row_end(ctx);

        // --- Sound ---
        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label(ctx, "Sound", c.NK_TEXT_LEFT);

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 110);
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
        c.nk_layout_row_push(ctx, 110);
        c.nk_label(ctx, "Buffer (ms):", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 150);
        var delay_f: f32 = @floatFromInt(cfg.delayms);
        delay_f = c.nk_slide_float(ctx, 50, delay_f, 250, 10);
        cfg.delayms = @intFromFloat(delay_f);
        c.nk_layout_row_push(ctx, 40);
        var delay_buf: [8:0]u8 = undefined;
        const delay_str = std.fmt.bufPrintZ(&delay_buf, "{d}", .{cfg.delayms}) catch "?";
        c.nk_label(ctx, delay_str.ptr, c.NK_TEXT_RIGHT);
        c.nk_layout_row_end(ctx);

        // --- Note ---
        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 16, 1);
        c.nk_label_colored(ctx, "* Auto-reset on close if changed", c.NK_TEXT_LEFT, c.nk_rgb(0xFF, 0x80, 0x40));
    }
    c.nk_end(ctx);

    if (handleClose(ctx, "Configure", &show_configure)) {
        if (!cfg_initial.eql(captureConfigState())) {
            cz.pccore_reset();
        }
    }
}

// ========================================================================
// Screen Option
// ========================================================================

fn drawScreenOption(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    if (!show_screen_opt) return;

    const dw: f32 = 320;
    const dh: f32 = 250;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const cfg = &cz.c.np2cfg;

    prepareDialog(ctx, "Screen Option", bounds, &reopen_screen_opt);

    if (c.nk_begin(ctx, "Screen Option", bounds, dialog_flags) != 0) {
        // --- GDC ---
        const prev_gdc = cfg.uPD72020;
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label(ctx, "GDC", c.NK_TEXT_LEFT);
        c.nk_layout_row_dynamic(ctx, 22, 2);
        {
            const was0: c_int = if (cfg.uPD72020 == 0) 1 else 0;
            if (c.nk_option_label(ctx, "uPD7220", was0) != 0 and was0 == 0)
                cfg.uPD72020 = 0;
            const was1: c_int = if (cfg.uPD72020 != 0) 1 else 0;
            if (c.nk_option_label(ctx, "uPD72020", was1) != 0 and was1 == 0)
                cfg.uPD72020 = 1;
        }
        if (cfg.uPD72020 != prev_gdc) {
            cz.usa_gdc_restorekacmode();
            cz.usa_gdc_alldraw2();
        }

        // --- Graphic Charger ---
        const prev_grcg = cfg.grcg;
        const prev_color16 = cfg.color16;
        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label(ctx, "Graphic Charger", c.NK_TEXT_LEFT);
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

        // --- Skipline ---
        const prev_skipline = cfg.skipline;
        const prev_skiplight = cfg.skiplight;
        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var skipline_v: c_int = if (cfg.skipline != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Skipline", &skipline_v);
        cfg.skipline = @intCast(@as(u32, @intCast(skipline_v)));

        if (cfg.skipline != 0) {
            c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
            c.nk_layout_row_push(ctx, 80);
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

        // --- Monochrome (LCD mode bit 0) ---
        const prev_lcd = cfg.LCD_MODE;
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var lcd_v: c_int = if (cfg.LCD_MODE & 1 != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Monochrome", &lcd_v);
        cfg.LCD_MODE = (cfg.LCD_MODE & 0xfe) | @as(u8, @intCast(@as(u32, @intCast(lcd_v)) & 1));
        if (cfg.LCD_MODE != prev_lcd) {
            cz.usa_pal_makelcdpal();
            cz.scrndraw_redraw();
        }
    }
    c.nk_end(ctx);

    _ = handleClose(ctx, "Screen Option", &show_screen_opt);
}

// ========================================================================
// Sound Mixer
// ========================================================================

fn drawSoundMixer(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    if (!show_sound_mixer) return;

    const dw: f32 = 300;
    const dh: f32 = 210;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;
    const bounds = c.nk_rect(dx, dy, dw, dh);
    const cfg = &cz.c.np2cfg;

    prepareDialog(ctx, "Sound Mixer", bounds, &reopen_sound_mixer);

    if (c.nk_begin(ctx, "Sound Mixer", bounds, dialog_flags) != 0) {
        const SliderEntry = struct { label: [*:0]const u8, val: *u8 };
        var entries = [_]SliderEntry{
            .{ .label = "FM", .val = &cfg.vol_fm },
            .{ .label = "PSG", .val = &cfg.vol_ssg },
            .{ .label = "ADPCM", .val = &cfg.vol_adpcm },
            .{ .label = "PCM", .val = &cfg.vol_pcm },
            .{ .label = "Rhythm", .val = &cfg.vol_rhythm },
        };

        for (&entries) |*entry| {
            c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
            c.nk_layout_row_push(ctx, 60);
            c.nk_label(ctx, entry.label, c.NK_TEXT_LEFT);
            c.nk_layout_row_push(ctx, 200);
            var f: f32 = @floatFromInt(entry.val.*);
            f = c.nk_slide_float(ctx, 0, f, 128, 1);
            entry.val.* = @intFromFloat(f);
            c.nk_layout_row_end(ctx);
        }

        c.nk_layout_row_dynamic(ctx, 6, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 28, 1);
        if (c.nk_button_label(ctx, "Defaults") != 0) {
            cfg.vol_fm = 64;
            cfg.vol_ssg = 64;
            cfg.vol_adpcm = 64;
            cfg.vol_pcm = 64;
            cfg.vol_rhythm = 64;
        }
    }
    c.nk_end(ctx);

    _ = handleClose(ctx, "Sound Mixer", &show_sound_mixer);
}
