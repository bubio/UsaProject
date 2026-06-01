const std = @import("std");
const cz = @import("c.zig");
const input = @import("input.zig");
const history = @import("history.zig");
const cli = @import("cli.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

const cfg_filename = "np2kai.cfg";
const section_header = "[NekoProjectIIkai]\n";

var dir_buf: [4096]u8 = undefined;
var dir_len: usize = 0;

pub fn setDataDir(dir: []const u8) void {
    if (dir.len >= dir_buf.len) return;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_len = dir.len;
}

fn cfgPathZ(buf: *[4096:0]u8) ?[*:0]const u8 {
    if (dir_len == 0) return null;
    const dir = dir_buf[0..dir_len];
    const result = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, cfg_filename }) catch return null;
    return result.ptr;
}

// --- Entry definitions matching NP2kai INI keys ---

const EntryKind = enum { u8_val, u16_val, u32_val };

const Entry = struct {
    key: []const u8,
    kind: EntryKind,
    ptr: *anyopaque,
};

fn u8entry(key: []const u8, ptr: *u8) Entry {
    return .{ .key = key, .kind = .u8_val, .ptr = ptr };
}
fn u16entry(key: []const u8, ptr: *u16) Entry {
    return .{ .key = key, .kind = .u16_val, .ptr = ptr };
}
fn u32entry(key: []const u8, ptr: *u32) Entry {
    return .{ .key = key, .kind = .u32_val, .ptr = ptr };
}

fn getEntries() [24]Entry {
    const cfg = &cz.c.np2cfg;
    return .{
        u32entry("clk_base", &cfg.baseclock),
        u32entry("clk_mult", &cfg.multiple),

        u8entry("uPD72020", &cfg.uPD72020),
        u8entry("Real_Pal", &cfg.RASTER),
        u8entry("realpal", &cfg.realpal),
        u8entry("LCD_MODE", &cfg.LCD_MODE),
        u8entry("skipline", &cfg.skipline),
        u16entry("skiplight", &cfg.skiplight),
        u8entry("GRC_MODE", &cfg.grcg),
        u8entry("color16", &cfg.color16),

        u32entry("SampleHz", &cfg.samplingrate),
        u16entry("Latencys", &cfg.delayms),
        u8entry("SNDboard", &cfg.SOUND_SW),
        u8entry("BEEP_vol", &cfg.BEEP_VOL),
        u8entry("volume_F", &cfg.vol_fm),
        u8entry("volume_S", &cfg.vol_ssg),
        u8entry("volume_A", &cfg.vol_adpcm),
        u8entry("volume_P", &cfg.vol_pcm),
        u8entry("volume_R", &cfg.vol_rhythm),

        u8entry("KEY_MODE", &cfg.KEY_MODE),
        u16entry("ExMemory", @ptrCast(&cfg.EXTMEM)),

        u8entry("FDDMotor", &cfg.MOTOR),
        u8entry("MOTORVOL", &cfg.MOTORVOL),
        u8entry("MSTRvol", &cfg.vol_master),
    };
}

// --- Load ---

pub fn load() void {
    var path_buf: [4096:0]u8 = undefined;
    const path = cfgPathZ(&path_buf) orelse return;

    const fp = c.fopen(path, "r") orelse return;
    defer _ = c.fclose(fp);

    // Sized for full disk-image paths (RecentFDD*/RecentHDD* values), not just
    // short numeric settings.
    var line_buf: [4096]u8 = undefined;
    var ents = getEntries();

    while (c.fgets(&line_buf, line_buf.len, fp) != null) {
        const line: []const u8 = std.mem.sliceTo(&line_buf, 0);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '[' or trimmed[0] == ';' or trimmed[0] == '#') continue;

        const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        const val = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        // np2cfg numeric entries
        for (&ents) |*e| {
            if (std.mem.eql(u8, key, e.key)) {
                setEntryValue(e, val);
                break;
            }
        }

        // String/special fields
        if (std.mem.eql(u8, key, "pc_model")) {
            if (val.len > 0 and val.len < 8) {
                var model_z: [8:0]u8 = std.mem.zeroes([8:0]u8);
                @memcpy(model_z[0..val.len], val);
                cz.np2_set_model(&model_z);
            }
        } else if (std.mem.eql(u8, key, "NOWAIT")) {
            cz.usa_set_nowait(std.fmt.parseInt(u8, val, 0) catch 0);
        } else if (std.mem.eql(u8, key, "DrawSkip")) {
            cz.usa_set_draw_skip(std.fmt.parseInt(u8, val, 0) catch 0);
        } else if (std.mem.eql(u8, key, "keyboard")) {
            cz.usa_set_keyboard(std.fmt.parseInt(u8, val, 0) catch 0);
        } else if (std.mem.eql(u8, key, "MouseSensi")) {
            input.setSensitivity(std.fmt.parseInt(u16, val, 0) catch 100);
        } else if (std.mem.startsWith(u8, key, "RecentFDD")) {
            if (val.len > 0) history.append(.fdd, val);
        } else if (std.mem.startsWith(u8, key, "RecentHDD")) {
            if (val.len > 0) history.append(.hdd, val);
        }
    }

    std.debug.print(">>> config loaded: {s}\n", .{std.mem.sliceTo(path, 0)});
}

fn setEntryValue(e: *Entry, val: []const u8) void {
    switch (e.kind) {
        .u8_val => {
            const p: *u8 = @ptrCast(@alignCast(e.ptr));
            p.* = std.fmt.parseInt(u8, val, 0) catch return;
        },
        .u16_val => {
            const p: *u16 = @ptrCast(@alignCast(e.ptr));
            p.* = std.fmt.parseInt(u16, val, 0) catch return;
        },
        .u32_val => {
            const p: *u32 = @ptrCast(@alignCast(e.ptr));
            p.* = std.fmt.parseInt(u32, val, 0) catch return;
        },
    }
}

// --- Save ---

pub fn save() void {
    var path_buf: [4096:0]u8 = undefined;
    const path = cfgPathZ(&path_buf) orelse return;

    const fp = c.fopen(path, "w") orelse {
        std.debug.print("!! config save failed\n", .{});
        return;
    };
    defer _ = c.fclose(fp);

    _ = c.fputs(section_header.ptr, fp);

    // model
    const model_slice = std.mem.sliceTo(&cz.c.np2cfg.model, 0);
    var mbuf: [64:0]u8 = undefined;
    const mline = std.fmt.bufPrintZ(&mbuf, "pc_model = {s}\n", .{model_slice}) catch return;
    _ = c.fputs(mline.ptr, fp);

    const ents = getEntries();
    var wbuf: [128:0]u8 = undefined;
    for (ents) |e| {
        const line = switch (e.kind) {
            .u8_val => blk: {
                const p: *const u8 = @ptrCast(@alignCast(e.ptr));
                break :blk std.fmt.bufPrintZ(&wbuf, "{s} = {d}\n", .{ e.key, p.* }) catch continue;
            },
            .u16_val => blk: {
                const p: *const u16 = @ptrCast(@alignCast(e.ptr));
                break :blk std.fmt.bufPrintZ(&wbuf, "{s} = {d}\n", .{ e.key, p.* }) catch continue;
            },
            .u32_val => blk: {
                const p: *const u32 = @ptrCast(@alignCast(e.ptr));
                break :blk std.fmt.bufPrintZ(&wbuf, "{s} = {d}\n", .{ e.key, p.* }) catch continue;
            },
        };
        _ = c.fputs(line.ptr, fp);
    }

    // np2oscfg fields
    var obuf: [64:0]u8 = undefined;
    writeU8Field(fp, &obuf, "NOWAIT", cz.usa_get_nowait());
    writeU8Field(fp, &obuf, "DrawSkip", cz.usa_get_draw_skip());
    writeU8Field(fp, &obuf, "keyboard", cz.usa_get_keyboard());
    if (std.fmt.bufPrintZ(&obuf, "MouseSensi = {d}\n", .{input.getSensitivity()})) |line| {
        _ = c.fputs(line.ptr, fp);
    } else |_| {}

    // Recent disk history, most-recent-first. Paths can be long, so use a buffer
    // sized to hold a 4096-byte path plus the "RecentXXXn = \n" framing.
    var pbuf: [4160:0]u8 = undefined;
    writeRecent(fp, &pbuf, .fdd, "RecentFDD");
    writeRecent(fp, &pbuf, .hdd, "RecentHDD");

    std.debug.print(">>> config saved: {s}\n", .{std.mem.sliceTo(path, 0)});
}

fn writeU8Field(fp: *c.FILE, buf: *[64:0]u8, key: []const u8, val: u8) void {
    const line = std.fmt.bufPrintZ(buf, "{s} = {d}\n", .{ key, val }) catch return;
    _ = c.fputs(line.ptr, fp);
}

fn writeRecent(fp: *c.FILE, buf: *[4160:0]u8, kind: cli.DiskKind, prefix: []const u8) void {
    for (0..history.count(kind)) |i| {
        const line = std.fmt.bufPrintZ(buf, "{s}{d} = {s}\n", .{ prefix, i, history.at(kind, i) }) catch continue;
        _ = c.fputs(line.ptr, fp);
    }
}
