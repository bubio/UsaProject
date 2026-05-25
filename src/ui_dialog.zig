const std = @import("std");
const cz = @import("c.zig");
const nk = @import("nk.zig");
const c = nk.c;

// --- Dialog visibility flags ---

var show_configure: bool = false;
var show_screen_opt: bool = false;
var show_sound_mixer: bool = false;

pub fn openConfigure() void {
    show_configure = true;
    cfg_snap = captureConfigSnap();
}
pub fn openScreenOption() void {
    show_screen_opt = true;
    scr_snap = captureScreenSnap();
}
pub fn openSoundMixer() void {
    show_sound_mixer = true;
    mix_snap = captureMixSnap();
}

pub fn draw(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    if (show_configure) drawConfigure(ctx, win_w, win_h);
    if (show_screen_opt) drawScreenOption(ctx, win_w, win_h);
    if (show_sound_mixer) drawSoundMixer(ctx, win_w, win_h);
}

// ========================================================================
// D1: Configure Dialog
// ========================================================================

const ConfigSnap = struct {
    baseclock: u32,
    multiple: u32,
    model_idx: u8,
    samplingrate: u32,
    delayms: u16,
};

var cfg_snap: ConfigSnap = undefined;

fn captureConfigSnap() ConfigSnap {
    return .{
        .baseclock = cz.c.np2cfg.baseclock,
        .multiple = cz.c.np2cfg.multiple,
        .model_idx = modelToIdx(cz.c.np2cfg.model),
        .samplingrate = cz.c.np2cfg.samplingrate,
        .delayms = cz.c.np2cfg.delayms,
    };
}

fn modelToIdx(model: [8]u8) u8 {
    if (model[0] == 'V' and model[1] == 'X') return 1;
    if (model[0] == 'V' and model[1] == 'M') return 0;
    return 2; // PC-286
}

const base_clocks = [_]u32{ 1996800, 2457600 };
const base_clock_labels = [_][*:0]const u8{ "1.9968 MHz", "2.4576 MHz" };
const multipliers = [_]u32{ 1, 2, 4, 5, 6, 8, 10, 12, 16, 20 };
const model_labels = [_][*:0]const u8{ "PC-9801VM", "PC-9801VX", "PC-286" };
const model_names = [_][*:0]const u8{ "VM", "VX", "PC286" };
const sample_rates = [_]u32{ 22050, 44100, 48000 };
const sample_rate_labels = [_][*:0]const u8{ "22050", "44100", "48000" };

fn drawConfigure(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 360;
    const dh: f32 = 340;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;

    if (c.nk_begin(ctx, "Configure", c.nk_rect(dx, dy, dw, dh), c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        // --- CPU ---
        c.nk_layout_row_dynamic(ctx, 20, 1);
        c.nk_label(ctx, "CPU", c.NK_TEXT_LEFT);

        c.nk_layout_row_dynamic(ctx, 22, 2);
        for (base_clocks, 0..) |clk, i| {
            if (c.nk_option_label(ctx, base_clock_labels[i], if (cfg_snap.baseclock == clk) @as(c_int, 1) else @as(c_int, 0)) != 0) {
                cfg_snap.baseclock = clk;
            }
        }

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 80);
        c.nk_label(ctx, "Multiple:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 200);

        var mul_idx: usize = 0;
        for (multipliers, 0..) |m, i| {
            if (cfg_snap.multiple == m) { mul_idx = i; break; }
        }
        const new_mul_idx: usize = @intCast(c.nk_combo(ctx, &multipliers_labels, multipliers_labels.len, @intCast(mul_idx), 22, c.nk_vec2(200, 200)));
        cfg_snap.multiple = multipliers[new_mul_idx];
        c.nk_layout_row_end(ctx);

        // --- Architecture ---
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 20, 1);
        c.nk_label(ctx, "Architecture", c.NK_TEXT_LEFT);
        c.nk_layout_row_dynamic(ctx, 22, 3);
        for (model_labels, 0..) |lbl, i| {
            if (c.nk_option_label(ctx, lbl, if (cfg_snap.model_idx == @as(u8, @intCast(i))) @as(c_int, 1) else @as(c_int, 0)) != 0) {
                cfg_snap.model_idx = @intCast(i);
            }
        }

        // --- Sound ---
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 20, 1);
        c.nk_label(ctx, "Sound", c.NK_TEXT_LEFT);

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 110);
        c.nk_label(ctx, "Sampling rate:", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 120);
        var sr_idx: usize = 1;
        for (sample_rates, 0..) |sr, i| {
            if (cfg_snap.samplingrate == sr) { sr_idx = i; break; }
        }
        const new_sr_idx: usize = @intCast(c.nk_combo(ctx, &sample_rate_labels, sample_rate_labels.len, @intCast(sr_idx), 22, c.nk_vec2(120, 100)));
        cfg_snap.samplingrate = sample_rates[new_sr_idx];
        c.nk_layout_row_end(ctx);

        c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
        c.nk_layout_row_push(ctx, 110);
        c.nk_label(ctx, "Buffer (ms):", c.NK_TEXT_LEFT);
        c.nk_layout_row_push(ctx, 200);
        var delay_f: f32 = @floatFromInt(cfg_snap.delayms);
        delay_f = c.nk_slide_float(ctx, 50, delay_f, 250, 10);
        cfg_snap.delayms = @intFromFloat(delay_f);
        c.nk_layout_row_end(ctx);

        // --- Note ---
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 18, 1);
        c.nk_label_colored(ctx, "* Reset required after changes", c.NK_TEXT_LEFT, c.nk_rgb(0xFF, 0x80, 0x40));

        // --- Buttons ---
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 28, 2);
        if (c.nk_button_label(ctx, "OK") != 0) {
            applyConfig();
            show_configure = false;
        }
        if (c.nk_button_label(ctx, "Cancel") != 0) {
            show_configure = false;
        }
    }
    c.nk_end(ctx);
}

const multipliers_labels = blk: {
    var labels: [multipliers.len][*:0]const u8 = undefined;
    for (multipliers, 0..) |m, i| {
        labels[i] = std.fmt.comptimePrint("{d}", .{m});
    }
    break :blk labels;
};

fn applyConfig() void {
    cz.c.np2cfg.baseclock = cfg_snap.baseclock;
    cz.c.np2cfg.multiple = cfg_snap.multiple;
    cz.np2_set_model(model_names[cfg_snap.model_idx]);
    cz.c.np2cfg.samplingrate = cfg_snap.samplingrate;
    cz.c.np2cfg.delayms = cfg_snap.delayms;
    cz.pccore_reset();
}

// ========================================================================
// D2: Screen Option Dialog
// ========================================================================

const ScreenSnap = struct {
    upd72020: u8,
    grcg: u8,
    color16: u8,
    skipline: u8,
    skiplight: u16,
    lcd_mode: u8,
};

var scr_snap: ScreenSnap = undefined;

fn captureScreenSnap() ScreenSnap {
    return .{
        .upd72020 = cz.c.np2cfg.uPD72020,
        .grcg = cz.c.np2cfg.grcg,
        .color16 = cz.c.np2cfg.color16,
        .skipline = cz.c.np2cfg.skipline,
        .skiplight = cz.c.np2cfg.skiplight,
        .lcd_mode = cz.c.np2cfg.LCD_MODE,
    };
}

fn drawScreenOption(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 320;
    const dh: f32 = 280;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;

    if (c.nk_begin(ctx, "Screen Option", c.nk_rect(dx, dy, dw, dh), c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        // GDC
        c.nk_layout_row_dynamic(ctx, 20, 1);
        c.nk_label(ctx, "GDC", c.NK_TEXT_LEFT);
        c.nk_layout_row_dynamic(ctx, 22, 2);
        if (c.nk_option_label(ctx, "uPD7220", if (scr_snap.upd72020 == 0) @as(c_int, 1) else @as(c_int, 0)) != 0) {
            scr_snap.upd72020 = 0;
        }
        if (c.nk_option_label(ctx, "uPD72020", if (scr_snap.upd72020 != 0) @as(c_int, 1) else @as(c_int, 0)) != 0) {
            scr_snap.upd72020 = 1;
        }

        // Graphic Charger
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 20, 1);
        c.nk_label(ctx, "Graphic Charger", c.NK_TEXT_LEFT);
        c.nk_layout_row_dynamic(ctx, 22, 4);
        const gc_labels = [_][*:0]const u8{ "None", "GRCG", "GRCG+", "EGC" };
        const gc_grcg_vals = [_]u8{ 0, 1, 1, 1 };
        const gc_color16_vals = [_]u8{ 0, 0, 1, 2 };
        var gc_idx: usize = 0;
        if (scr_snap.grcg != 0) {
            if (scr_snap.color16 == 0) gc_idx = 1 else if (scr_snap.color16 == 1) gc_idx = 2 else gc_idx = 3;
        }
        for (gc_labels, 0..) |lbl, i| {
            if (c.nk_option_label(ctx, lbl, if (gc_idx == i) @as(c_int, 1) else @as(c_int, 0)) != 0) {
                scr_snap.grcg = gc_grcg_vals[i];
                scr_snap.color16 = gc_color16_vals[i];
            }
        }

        // Skipline
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var skipline_check: c_int = if (scr_snap.skipline != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "Skipline", &skipline_check);
        scr_snap.skipline = @intCast(@as(u32, @intCast(skipline_check)));

        if (scr_snap.skipline != 0) {
            c.nk_layout_row_begin(ctx, c.NK_STATIC, 22, 2);
            c.nk_layout_row_push(ctx, 80);
            c.nk_label(ctx, "Brightness:", c.NK_TEXT_LEFT);
            c.nk_layout_row_push(ctx, 180);
            var sl_f: f32 = @floatFromInt(scr_snap.skiplight);
            sl_f = c.nk_slide_float(ctx, 0, sl_f, 255, 1);
            scr_snap.skiplight = @intFromFloat(sl_f);
            c.nk_layout_row_end(ctx);
        }

        // LCD
        c.nk_layout_row_dynamic(ctx, 22, 1);
        var lcd_check: c_int = if (scr_snap.lcd_mode != 0) 1 else 0;
        _ = c.nk_checkbox_label(ctx, "LCD mode", &lcd_check);
        scr_snap.lcd_mode = @intCast(@as(u32, @intCast(lcd_check)));

        // Buttons
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 28, 2);
        if (c.nk_button_label(ctx, "OK") != 0) {
            applyScreenOption();
            show_screen_opt = false;
        }
        if (c.nk_button_label(ctx, "Cancel") != 0) {
            show_screen_opt = false;
        }
    }
    c.nk_end(ctx);
}

fn applyScreenOption() void {
    cz.c.np2cfg.uPD72020 = scr_snap.upd72020;
    cz.c.np2cfg.grcg = scr_snap.grcg;
    cz.c.np2cfg.color16 = scr_snap.color16;
    cz.c.np2cfg.skipline = scr_snap.skipline;
    cz.c.np2cfg.skiplight = scr_snap.skiplight;
    cz.c.np2cfg.LCD_MODE = scr_snap.lcd_mode;
}

// ========================================================================
// D3: Sound Mixer Dialog
// ========================================================================

const MixSnap = struct {
    fm: u8,
    ssg: u8,
    adpcm: u8,
    pcm: u8,
    rhythm: u8,
};

var mix_snap: MixSnap = undefined;

fn captureMixSnap() MixSnap {
    return .{
        .fm = cz.c.np2cfg.vol_fm,
        .ssg = cz.c.np2cfg.vol_ssg,
        .adpcm = cz.c.np2cfg.vol_adpcm,
        .pcm = cz.c.np2cfg.vol_pcm,
        .rhythm = cz.c.np2cfg.vol_rhythm,
    };
}

fn drawSoundMixer(ctx: *c.nk_context, win_w: u32, win_h: u32) void {
    const dw: f32 = 300;
    const dh: f32 = 260;
    const dx = (@as(f32, @floatFromInt(win_w)) - dw) / 2.0;
    const dy = (@as(f32, @floatFromInt(win_h)) - dh) / 2.0;

    if (c.nk_begin(ctx, "Sound Mixer", c.nk_rect(dx, dy, dw, dh), c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_NO_SCROLLBAR) != 0) {
        const SliderEntry = struct { label: [*:0]const u8, val: *u8 };
        var entries = [_]SliderEntry{
            .{ .label = "FM", .val = &mix_snap.fm },
            .{ .label = "PSG", .val = &mix_snap.ssg },
            .{ .label = "ADPCM", .val = &mix_snap.adpcm },
            .{ .label = "PCM", .val = &mix_snap.pcm },
            .{ .label = "Rhythm", .val = &mix_snap.rhythm },
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

        // Defaults + OK + Cancel
        c.nk_layout_row_dynamic(ctx, 8, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 28, 3);
        if (c.nk_button_label(ctx, "Defaults") != 0) {
            mix_snap = .{ .fm = 64, .ssg = 64, .adpcm = 64, .pcm = 64, .rhythm = 64 };
        }
        if (c.nk_button_label(ctx, "OK") != 0) {
            applySoundMixer();
            show_sound_mixer = false;
        }
        if (c.nk_button_label(ctx, "Cancel") != 0) {
            show_sound_mixer = false;
        }
    }
    c.nk_end(ctx);
}

fn applySoundMixer() void {
    cz.c.np2cfg.vol_fm = mix_snap.fm;
    cz.c.np2cfg.vol_ssg = mix_snap.ssg;
    cz.c.np2cfg.vol_adpcm = mix_snap.adpcm;
    cz.c.np2cfg.vol_pcm = mix_snap.pcm;
    cz.c.np2cfg.vol_rhythm = mix_snap.rhythm;
}
