const std = @import("std");

pub const DiskKind = enum { fdd, hdd };

pub const Disk = struct {
    kind: DiskKind,
    path: [:0]const u8,
};

pub const Options = struct {
    model: ?[:0]const u8 = null,
    disks: []Disk = &.{},
    help: bool = false,
    audio_capture: ?[:0]const u8 = null,
    audio_autotest: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self.model) |m| allocator.free(m);
        if (self.audio_capture) |p| allocator.free(p);
        for (self.disks) |d| allocator.free(d.path);
        allocator.free(self.disks);
    }
};

pub const ParseError = error{
    MissingValue,
    UnknownOption,
    ModelTooLong,
    TooManyFdd,
    TooManyHdd,
    UnknownExtension,
    OutOfMemory,
};

pub const valid_models = [_][]const u8{ "VM", "VX", "286", "EPSON" };

pub const max_fdd = 4;
pub const max_hdd = 4;
pub const model_max_len = 7; // NP2CFG.model is OEMCHAR[8] — leave room for NUL.

const fdd_exts = [_][]const u8{
    ".d88", ".88d", ".d98", ".98d", ".fdi", ".xdf", ".hdm", ".dup",
    ".2hd", ".tfd", ".nfd", ".hd4", ".hd5", ".hd9", ".fdd", ".h01",
    ".hdb", ".ddb", ".dd6", ".dd9", ".dcp", ".dcu", ".flp", ".img",
    ".ima", ".bin", ".fim",
};

const hdd_exts = [_][]const u8{
    ".thd", ".nhd", ".hdi", ".vhd", ".slh", ".hdn", ".hdd", ".cmd",
};

pub const usage_text =
    \\Usage: UsaProject [options] [DISK_PATH ...]
    \\
    \\Options:
    \\  --model NAME    PC-98 model: VM, VX, 286, EPSON (default: VX)
    \\  -h, --help      Show this help
    \\
    \\Positional DISK_PATH arguments are routed by extension:
    \\  FDD (max 4): .d88 .88d .d98 .98d .fdi .xdf .hdm .dup .2hd .tfd
    \\               .nfd .fdd .img .ima .bin .fim .flp .hd4 .hd5 .hd9
    \\               .h01 .hdb .ddb .dd6 .dd9 .dcp .dcu
    \\  HDD (max 4): .thd .nhd .hdi .vhd .slh .hdn .hdd .cmd
    \\
;

fn classifyExt(path: []const u8) ?DiskKind {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext_raw = path[dot..];
    var buf: [8]u8 = undefined;
    if (ext_raw.len > buf.len) return null;
    const ext = std.ascii.lowerString(buf[0..ext_raw.len], ext_raw);
    for (fdd_exts) |e| if (std.mem.eql(u8, e, ext)) return .fdd;
    for (hdd_exts) |e| if (std.mem.eql(u8, e, ext)) return .hdd;
    return null;
}

/// Parse argv (excluding program name). Caller owns the returned Options
/// and must call `deinit`. On error, all partial allocations are released.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var disks: std.ArrayList(Disk) = .empty;
    errdefer {
        for (disks.items) |d| allocator.free(d.path);
        disks.deinit(allocator);
        if (opts.model) |m| allocator.free(m);
    }

    var fdd_count: usize = 0;
    var hdd_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.help = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = args[i];
            if (v.len > model_max_len) return error.ModelTooLong;
            opts.model = try allocator.dupeZ(u8, v);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--model=")) {
            const v = a["--model=".len..];
            if (v.len > model_max_len) return error.ModelTooLong;
            opts.model = try allocator.dupeZ(u8, v);
            continue;
        }
        if (std.mem.eql(u8, a, "--audio-capture")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.audio_capture = try allocator.dupeZ(u8, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--audio-capture=")) {
            opts.audio_capture = try allocator.dupeZ(u8, a["--audio-capture=".len..]);
            continue;
        }
        if (std.mem.eql(u8, a, "--audio-autotest")) {
            opts.audio_autotest = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownOption;
        }
        // Positional: disk image
        const kind = classifyExt(a) orelse return error.UnknownExtension;
        switch (kind) {
            .fdd => {
                if (fdd_count >= max_fdd) return error.TooManyFdd;
                fdd_count += 1;
            },
            .hdd => {
                if (hdd_count >= max_hdd) return error.TooManyHdd;
                hdd_count += 1;
            },
        }
        const path = try allocator.dupeZ(u8, a);
        try disks.append(allocator, .{ .kind = kind, .path = path });
    }

    opts.disks = try disks.toOwnedSlice(allocator);
    return opts;
}

// ---------- tests ----------

const testing = std.testing;

test "parse — empty argv yields defaults" {
    var opts = try parse(testing.allocator, &.{});
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.model == null);
    try testing.expectEqual(@as(usize, 0), opts.disks.len);
    try testing.expect(!opts.help);
}

test "parse — --model VX" {
    var opts = try parse(testing.allocator, &.{ "--model", "VX" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("VX", opts.model.?);
}

test "parse — --model=EPSON" {
    var opts = try parse(testing.allocator, &.{"--model=EPSON"});
    defer opts.deinit(testing.allocator);
    try testing.expectEqualStrings("EPSON", opts.model.?);
}

test "parse — --model missing value" {
    try testing.expectError(error.MissingValue, parse(testing.allocator, &.{"--model"}));
}

test "parse — --model too long" {
    try testing.expectError(error.ModelTooLong, parse(testing.allocator, &.{ "--model", "TOOLONGMODEL" }));
}

test "parse — -h sets help" {
    var opts = try parse(testing.allocator, &.{"-h"});
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.help);
}

test "parse — unknown option" {
    try testing.expectError(error.UnknownOption, parse(testing.allocator, &.{"--bogus"}));
}

test "parse — positional FDD by extension" {
    var opts = try parse(testing.allocator, &.{"game.d88"});
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), opts.disks.len);
    try testing.expectEqual(DiskKind.fdd, opts.disks[0].kind);
    try testing.expectEqualStrings("game.d88", opts.disks[0].path);
}

test "parse — positional HDD by extension" {
    var opts = try parse(testing.allocator, &.{"work.hdi"});
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(DiskKind.hdd, opts.disks[0].kind);
}

test "parse — extension case-insensitive" {
    var opts = try parse(testing.allocator, &.{"GAME.D88"});
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(DiskKind.fdd, opts.disks[0].kind);
}

test "parse — multiple FDDs preserve order" {
    var opts = try parse(testing.allocator, &.{ "a.d88", "b.fdi", "c.hdm" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), opts.disks.len);
    try testing.expectEqualStrings("a.d88", opts.disks[0].path);
    try testing.expectEqualStrings("b.fdi", opts.disks[1].path);
    try testing.expectEqualStrings("c.hdm", opts.disks[2].path);
}

test "parse — mixed FDD and HDD" {
    var opts = try parse(testing.allocator, &.{ "boot.d88", "data.hdi" });
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(DiskKind.fdd, opts.disks[0].kind);
    try testing.expectEqual(DiskKind.hdd, opts.disks[1].kind);
}

test "parse — too many FDDs" {
    try testing.expectError(
        error.TooManyFdd,
        parse(testing.allocator, &.{ "a.d88", "b.d88", "c.d88", "d.d88", "e.d88" }),
    );
}

test "parse — too many HDDs" {
    try testing.expectError(
        error.TooManyHdd,
        parse(testing.allocator, &.{ "a.hdi", "b.hdi", "c.hdi", "d.hdi", "e.hdi" }),
    );
}

test "parse — unknown extension" {
    try testing.expectError(error.UnknownExtension, parse(testing.allocator, &.{"readme.txt"}));
}

test "parse — disk paths are sentinel-terminated" {
    var opts = try parse(testing.allocator, &.{"a.d88"});
    defer opts.deinit(testing.allocator);
    const p = opts.disks[0].path;
    try testing.expectEqual(@as(u8, 0), p.ptr[p.len]);
}

test "parse — model is sentinel-terminated" {
    var opts = try parse(testing.allocator, &.{ "--model", "286" });
    defer opts.deinit(testing.allocator);
    const m = opts.model.?;
    try testing.expectEqual(@as(u8, 0), m.ptr[m.len]);
}
