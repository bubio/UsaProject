//! Archive (zip) support for disk images.
//!
//! NP2kai's core has no compressed-archive support (see
//! docs/np2kai-archive-support.md). Per AGENTS.md's portability/maintenance
//! philosophy we keep the core untouched and handle archives in the Zig app
//! layer: an archive is unpacked into a per-archive cache directory and the
//! contained raw disk images are then mounted into the core.
//!
//! Strategy (doc "method B" — decompressed copy as canonical, key = archive
//! hash): the extraction is persisted under <datadir>/cache/<hash>/ and reused
//! when the same archive is opened again. Writes (game saves) land in the
//! extracted copy; they are never written back into the zip.
//!
//! Only zip (store/deflate) is handled, via std.zip. Encrypted/multi-disk zips
//! and other formats (lzh, gz) are unsupported and surface as errors.

const std = @import("std");
const cli = @import("cli.zig");
const platform = @import("platform.zig");

pub const Error = error{
    /// The archive unpacked successfully but contained no FDD/HDD image.
    NoDiskImageInArchive,
    /// Hashing, unpacking, or scanning the archive failed.
    ExtractFailed,
    OutOfMemory,
};

/// A disk image extracted from an archive. `path` and `name` point into the
/// cache/arena and are owned by the containing `ImageSet`.
pub const Image = struct {
    path: [:0]const u8,
    /// Human-facing label for disk-selection UI: the original archive filename
    /// when it survives ASCII sanitization, else "Disk N". See collectImages.
    name: [:0]const u8,
    kind: cli.DiskKind, // always .fdd or .hdd
};

/// The set of disk images unpacked from one archive. All `Image.path` strings
/// are backed by `arena`; call `deinit` once the paths are no longer needed
/// (the extracted files on disk stay in the cache and are not removed).
pub const ImageSet = struct {
    images: []Image,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ImageSet) void {
        self.arena.deinit();
    }
};

/// True if `path` has an archive extension we handle.
pub fn isArchive(path: []const u8) bool {
    return cli.classifyExt(path) == .archive;
}

/// Unpack `archive_path` (reusing the cache if already extracted) and return
/// every FDD/HDD image it contains, sorted by filename.
pub fn extractImages(allocator: std.mem.Allocator, archive_path: [:0]const u8) Error!ImageSet {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Cache root: <datadir>/cache
    const data_dir = platform.resolveDataDir(allocator) catch return Error.ExtractFailed;
    defer allocator.free(data_dir);
    const cache_root = std.fmt.allocPrintSentinel(allocator, "{s}/cache", .{data_dir}, 0) catch
        return Error.OutOfMemory;
    defer allocator.free(cache_root);
    platform.ensureExists(cache_root) catch |e|
        std.debug.print("!! could not create cache dir '{s}': {s}\n", .{ cache_root, @errorName(e) });

    const key = hashArchive(io, archive_path) catch |e| {
        std.debug.print("!! could not hash archive '{s}': {s}\n", .{ archive_path, @errorName(e) });
        return Error.ExtractFailed;
    };
    const cache_dir = std.fmt.allocPrint(allocator, "{s}/{x:0>16}", .{ cache_root, key }) catch
        return Error.OutOfMemory;
    defer allocator.free(cache_dir);

    ensureExtracted(io, allocator, archive_path, cache_dir) catch |e| {
        std.debug.print("!! archive extract failed for '{s}': {s}\n", .{ archive_path, @errorName(e) });
        return Error.ExtractFailed;
    };

    return collectImages(io, allocator, cache_dir) catch |e| switch (e) {
        error.NoDiskImageInArchive => Error.NoDiskImageInArchive,
        else => blk: {
            std.debug.print("!! could not scan extracted archive '{s}': {s}\n", .{ cache_dir, @errorName(e) });
            break :blk Error.ExtractFailed;
        },
    };
}

const chunk_len: u64 = 64 * 1024;

/// Content-addressed cache key. Hashing the whole file would be slow for large
/// HDD images on every launch, so we combine size + head + tail (constant time,
/// negligible collision risk) — the "size + head/tail chunk" compromise from
/// docs/np2kai-archive-support.md.
fn hashArchive(io: std.Io, archive_path: [:0]const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    const size = try fr.getSize();

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&size));

    var chunk: [chunk_len]u8 = undefined;

    const head: usize = @intCast(@min(size, chunk_len));
    try fr.seekTo(0);
    try fr.interface.readSliceAll(chunk[0..head]);
    hasher.update(chunk[0..head]);

    if (size > chunk_len) {
        const tail: usize = @intCast(@min(size - chunk_len, chunk_len));
        try fr.seekTo(size - tail);
        try fr.interface.readSliceAll(chunk[0..tail]);
        hasher.update(chunk[0..tail]);
    }
    return hasher.final();
}

/// Ensure `cache_dir` holds a complete extraction of the archive. A successful
/// run leaves a ".extracted" marker; its presence means we can reuse the cache.
fn ensureExtracted(io: std.Io, allocator: std.mem.Allocator, archive_path: [:0]const u8, cache_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const marker = try std.fmt.allocPrint(allocator, "{s}/.extracted", .{cache_dir});
    defer allocator.free(marker);

    // Already fully extracted? Reuse it.
    if (cwd.access(io, marker, .{})) |_| return else |_| {}

    // Drop any partial leftovers from an interrupted previous run.
    cwd.deleteTree(io, cache_dir) catch {};

    var dest = try cwd.createDirPathOpen(io, cache_dir, .{ .open_options = .{ .iterate = true } });
    defer dest.close(io);

    unpackImages(io, allocator, archive_path, dest) catch |e| {
        // Roll back so a later retry starts from a clean directory.
        cwd.deleteTree(io, cache_dir) catch {};
        return e;
    };

    var mf = try cwd.createFile(io, marker, .{});
    mf.close(io);
}

/// Write the FDD/HDD images contained in the archive into `dest`.
///
/// We do NOT use std.zip.extract: PC-98 game archives routinely store entry
/// names in CP932 (Shift-JIS) and inside a top-level directory, and macOS/APFS
/// rejects non-UTF-8 filenames (error.BadPathName). Instead we extract only the
/// disk images, each under a safe name "<NNNN>_<sanitized-basename>" assigned in
/// original filename order, so collectImages' path sort reproduces that order on
/// reuse and can recover a display label from the basename. Non-image entries
/// (readme, directories) are skipped — the emulator only needs the raw images.
/// Extensions are ASCII even within CP932 names ('.' and '/' never occur as
/// Shift-JIS trailing bytes), so classification stays valid.
fn unpackImages(io: std.Io, allocator: std.mem.Allocator, archive_path: [:0]const u8, dest: std.Io.Dir) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var rbuf: [chunk_len]u8 = undefined;
    var fr = file.reader(io, &rbuf);

    var iter = try std.zip.Iterator.init(&fr);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Cand = struct { name: []const u8, entry: std.zip.Iterator.Entry };
    var cands: std.ArrayList(Cand) = .empty;

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > name_buf.len) continue;
        const name = name_buf[0..entry.filename_len];
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        if (name[name.len - 1] == '/' or name[name.len - 1] == '\\') continue; // directory entry
        const kind = cli.classifyExt(name) orelse continue;
        if (kind == .archive) continue;
        try cands.append(a, .{ .name = try a.dupe(u8, name), .entry = entry });
    }

    std.mem.sort(Cand, cands.items, {}, struct {
        fn lt(_: void, x: Cand, y: Cand) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);

    for (cands.items, 0..) |cand, i| {
        const base = basename(cand.name);
        const dot = std.mem.lastIndexOfScalar(u8, cand.name, '.').?;
        const ext = cand.name[dot..]; // ASCII even within CP932 names
        // "<NNNN>_<sanitized>". The sanitized basename keeps a recoverable
        // display label; if it drops everything (all-CP932 name) we still have
        // the ASCII extension so classifyExt and collectImages keep working.
        var san_buf: [std.fs.max_path_bytes]u8 = undefined;
        const san = sanitizeAscii(&san_buf, base);
        var out_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const out_name = if (san.len == 0)
            try std.fmt.bufPrint(&out_name_buf, "{d:0>4}_{s}", .{ i, ext })
        else
            try std.fmt.bufPrint(&out_name_buf, "{d:0>4}_{s}", .{ i, san });
        try writeEntry(io, &fr, cand.entry, dest, out_name);
    }
}

/// The path component after the last '/' or '\'. PC-98 archives often store a
/// top-level directory; the disk label lives in the final component.
fn basename(name: []const u8) []const u8 {
    var start: usize = 0;
    for (name, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return name[start..];
}

/// Copy the printable-ASCII filename-safe bytes of `src` into `dst`, dropping
/// everything else (CP932 bytes, control chars, path separators). Returns the
/// written slice. Used both to build the on-disk cache name and to recover a
/// display label from it later.
fn sanitizeAscii(dst: []u8, src: []const u8) []u8 {
    var n: usize = 0;
    for (src) |ch| {
        const ok = switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-', ' ' => true,
            else => false,
        };
        if (ok and n < dst.len) {
            dst[n] = ch;
            n += 1;
        }
    }
    return dst[0..n];
}

/// Decompress a single zip entry's data into `dest`/`out_name` (store/deflate).
fn writeEntry(io: std.Io, fr: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, dest: std.Io.Dir, out_name: []const u8) !void {
    try fr.seekTo(entry.file_offset);
    const local = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig))
        return error.ZipBadFileOffset;
    const data_off = entry.file_offset + @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        local.filename_len + local.extra_len;
    try fr.seekTo(data_off);

    var out = try dest.createFile(io, out_name, .{});
    defer out.close(io);
    var wbuf: [chunk_len]u8 = undefined;
    var fw = out.writer(io, &wbuf);

    switch (entry.compression_method) {
        .store => try fr.interface.streamExact64(&fw.interface, entry.uncompressed_size),
        .deflate => {
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var dec = std.compress.flate.Decompress.init(&fr.interface, .raw, &flate_buf);
            try dec.reader.streamExact64(&fw.interface, entry.uncompressed_size);
        },
        else => return error.UnsupportedCompressionMethod,
    }
    try fw.end();
}

/// Recursively scan `cache_dir` for FDD/HDD images, returning them sorted by
/// path. Files with unrecognized extensions (and the ".extracted" marker) are
/// skipped.
fn collectImages(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8) !ImageSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(Image) = .empty;

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const kind = cli.classifyExt(entry.basename) orelse continue;
        if (kind == .archive) continue; // ignore nested archives
        const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ cache_dir, entry.path }, 0);
        // `name` is filled in after sorting so the "Disk N" fallback numbers
        // images in their final display order.
        try list.append(a, .{ .path = full, .name = "", .kind = kind });
    }

    if (list.items.len == 0) return error.NoDiskImageInArchive;

    const images = try list.toOwnedSlice(a);
    std.mem.sort(Image, images, {}, lessByPath);
    for (images, 0..) |*img, i| {
        const label = stripIndexPrefix(basename(img.path));
        img.name = if (hasBlankStem(label))
            try std.fmt.allocPrintSentinel(a, "Disk {d}", .{i + 1}, 0)
        else
            try a.dupeZ(u8, label);
    }
    return .{ .images = images, .arena = arena };
}

/// Drop the "<NNNN>_" extraction prefix that unpackImages prepends, recovering
/// the sanitized original basename. Returns the input unchanged if it lacks the
/// prefix (e.g. plain on-disk images that were never archive-extracted).
fn stripIndexPrefix(name: []const u8) []const u8 {
    if (name.len < 5 or name[4] != '_') return name;
    for (name[0..4]) |ch| if (ch < '0' or ch > '9') return name;
    return name[5..];
}

/// True when nothing meaningful precedes the extension (e.g. ".fdi" recovered
/// from an all-CP932 name), so the caller falls back to a "Disk N" label.
fn hasBlankStem(label: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, label, '.') orelse label.len;
    return std.mem.trim(u8, label[0..dot], "_ -").len == 0;
}

fn lessByPath(_: void, lhs: Image, rhs: Image) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

// ---------- tests ----------

const testing = std.testing;

test "isArchive — zip detected, disk images not" {
    try testing.expect(isArchive("game.zip"));
    try testing.expect(isArchive("GAME.ZIP"));
    try testing.expect(!isArchive("game.d88"));
    try testing.expect(!isArchive("work.hdi"));
    try testing.expect(!isArchive("noext"));
}

test "basename — strips top-level directory" {
    try testing.expectEqualStrings("a.fdi", basename("dir/a.fdi"));
    try testing.expectEqualStrings("a.fdi", basename("x\\y\\a.fdi"));
    try testing.expectEqualStrings("a.fdi", basename("a.fdi"));
}

test "sanitizeAscii — keeps safe bytes, drops the rest" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("GAME_A.FDI", sanitizeAscii(&buf, "GAME_A.FDI"));
    try testing.expectEqualStrings("Disk 1.fdi", sanitizeAscii(&buf, "Disk 1.fdi"));
    // CP932 (Shift-JIS) bytes are dropped; the ASCII extension survives.
    try testing.expectEqualStrings(".fdi", sanitizeAscii(&buf, "\x8b\xe0\x8c\xed.fdi"));
    try testing.expectEqualStrings("", sanitizeAscii(&buf, "\x8b\xe0\x8c\xed"));
}

test "stripIndexPrefix — recovers the original label" {
    try testing.expectEqualStrings("GAME_A.FDI", stripIndexPrefix("0003_GAME_A.FDI"));
    try testing.expectEqualStrings(".fdi", stripIndexPrefix("0000_.fdi"));
    // No "<NNNN>_" prefix: returned unchanged.
    try testing.expectEqualStrings("plain.fdi", stripIndexPrefix("plain.fdi"));
    try testing.expectEqualStrings("12ab_x.fdi", stripIndexPrefix("12ab_x.fdi"));
}

test "hasBlankStem — extension-only labels fall back to Disk N" {
    try testing.expect(hasBlankStem(".fdi")); // all-CP932 name sanitized away
    try testing.expect(hasBlankStem("_ .hdi"));
    try testing.expect(!hasBlankStem("GAME_A.FDI"));
    try testing.expect(!hasBlankStem("disk1.fdi"));
}
