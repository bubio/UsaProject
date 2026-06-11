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

/// NP2kai codecnv: CP932 (Shift-JIS) → UTF-8。バイナリモード (cchIn != -1) では
/// 書き込みバイト数を返し、NUL 終端しない。`core/np2kai/codecnv/sjisucs2.c` 内で
/// 自己完結 (テーブル駆動、コアのグローバルに非依存)。
extern fn codecnv_sjistoutf8(out: ?[*]u8, cchOut: c_uint, in: [*]const u8, cchIn: c_uint) c_uint;

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
    /// Human-facing label for disk-selection UI: the original (UTF-8, Japanese-
    /// capable) filename, or "Disk N" when no meaningful name remains. See
    /// collectImages.
    name: [:0]const u8,
    kind: cli.DiskKind, // always .fdd or .hdd
};

/// The set of disk images unpacked from one archive (or scanned from a folder).
/// All `Image.path`/`Image.name` and `source` strings are backed by `arena`;
/// call `deinit` once they are no longer needed (the files on disk stay put).
pub const ImageSet = struct {
    images: []Image,
    /// Human-facing label for the source the images came from: the archive
    /// filename or the containing folder name (UTF-8). Shown as the section
    /// header in the drive menu's disk-swap list.
    source: [:0]const u8,
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

    var set = collectImages(io, allocator, cache_dir) catch |e| switch (e) {
        error.NoDiskImageInArchive => return Error.NoDiskImageInArchive,
        else => {
            std.debug.print("!! could not scan extracted archive '{s}': {s}\n", .{ cache_dir, @errorName(e) });
            return Error.ExtractFailed;
        },
    };
    // Label the swap list with the original archive filename (sanitized).
    const a = set.arena.allocator();
    set.source = displaySource(a, basename(archive_path), "Archive") catch return Error.OutOfMemory;
    return set;
}

/// Scan the folder containing `file_path` for sibling images of `kind` (so the
/// drive menu can offer them as swap targets), returning them sorted by path.
/// `source` is the folder name. Real on-disk paths are used directly; the core
/// opens UTF-8 paths, and display labels keep their UTF-8 (Japanese) names.
pub fn scanFolder(allocator: std.mem.Allocator, file_path: [:0]const u8, kind: cli.DiskKind) Error!ImageSet {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sep_idx = lastSep(file_path) orelse return Error.ExtractFailed;
    const dir_path = dirname(file_path);
    if (dir_path.len == 0) return Error.ExtractFailed;
    // Rebuild sibling paths with the SAME separator the input used (backslash or
    // forward slash) so they round-trip with the original path — `indexOfPath`
    // compares bytes exactly to find which sibling is the mounted disk.
    const sep = file_path[sep_idx];

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return Error.ExtractFailed;
    defer dir.close(io);

    var list: std.ArrayList(Image) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return Error.ExtractFailed) |entry| {
        if (entry.kind != .file) continue;
        if (cli.classifyExt(entry.name) != kind) continue;
        const full = std.fmt.allocPrintSentinel(a, "{s}{c}{s}", .{ dir_path, sep, entry.name }, 0) catch
            return Error.OutOfMemory;
        try list.append(a, .{ .path = full, .name = "", .kind = kind });
    }

    if (list.items.len == 0) return Error.NoDiskImageInArchive;

    const images = list.toOwnedSlice(a) catch return Error.OutOfMemory;
    std.mem.sort(Image, images, {}, lessByPath);
    for (images, 0..) |*img, i| {
        img.name = displayName(a, basename(img.path), i) catch return Error.OutOfMemory;
    }
    const source = displaySource(a, basename(dir_path), "Folder") catch return Error.OutOfMemory;
    return .{ .images = images, .source = source, .arena = arena };
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
/// rejects non-UTF-8 filenames (error.BadPathName). Instead we decode each name
/// to UTF-8 (see decodeName) and extract only the disk images, each under a safe
/// name "<NNNN>_<sanitized-basename>" assigned in original filename order, so
/// collectImages' path sort reproduces that order on reuse and can recover a
/// (now Japanese-capable) display label from the basename. Non-image entries
/// (readme, directories) are skipped — the emulator only needs the raw images.
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
    var dec_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > name_buf.len) continue;
        const name = name_buf[0..entry.filename_len];
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        if (name[name.len - 1] == '/' or name[name.len - 1] == '\\') continue; // directory entry
        // Decode to UTF-8 (CP932 → UTF-8, or pass-through if already UTF-8) so the
        // cache name — and thus the recovered display label — keeps Japanese names.
        const decoded = decodeName(&dec_buf, name);
        const kind = cli.classifyExt(decoded) orelse continue;
        if (kind == .archive) continue;
        try cands.append(a, .{ .name = try a.dupe(u8, decoded), .entry = entry });
    }

    std.mem.sort(Cand, cands.items, {}, struct {
        fn lt(_: void, x: Cand, y: Cand) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);

    for (cands.items, 0..) |cand, i| {
        const base = basename(cand.name); // decoded UTF-8 basename
        const dot = std.mem.lastIndexOfScalar(u8, cand.name, '.').?;
        const ext = cand.name[dot..]; // extension is ASCII
        // "<NNNN>_<sanitized>". The sanitized basename keeps a recoverable
        // display label; if it drops everything we still have the ASCII
        // extension so classifyExt and collectImages keep working.
        var san_buf: [std.fs.max_path_bytes]u8 = undefined;
        const san = sanitizeFsName(&san_buf, base);
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

/// Decode an archive entry name to UTF-8. Modern zips store UTF-8 names; older
/// PC-98 archives store CP932 (Shift-JIS). std.zip doesn't expose the UTF-8 flag
/// (general-purpose bit 11), so we sniff instead: a name that is already valid
/// UTF-8 is passed through, otherwise it is decoded from CP932 via NP2kai's
/// codecnv. The decoded bytes land in `dst`; the returned slice points into
/// `dst` (CP932 path) or `raw` (already-UTF-8 path).
fn decodeName(dst: []u8, raw: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return raw;
    // Binary mode (cchIn != -1) returns bytes written and does not NUL-terminate.
    const n = codecnv_sjistoutf8(dst.ptr, @intCast(dst.len), raw.ptr, @intCast(raw.len));
    const out = dst[0..@min(n, dst.len)];
    // Defensive: if the conversion produced something unexpected, keep raw.
    return if (std.unicode.utf8ValidateSlice(out)) out else raw;
}

/// Copy the filename-safe bytes of `src` (a UTF-8 string) into `dst`, dropping
/// only control chars, path separators, and characters illegal in filenames on
/// Windows. Bytes ≥ 0x80 (multi-byte UTF-8, e.g. Japanese) are preserved, so the
/// on-disk cache name keeps a renderable label that we recover later. The
/// decoded UTF-8 is valid on APFS/NTFS/ext.
fn sanitizeFsName(dst: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    for (src) |ch| {
        const drop = ch < 0x20 or switch (ch) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => true,
            else => false,
        };
        if (!drop and n < dst.len) {
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
        img.name = try displayName(a, stripIndexPrefix(basename(img.path)), i);
    }
    // `source` is filled in by extractImages, which knows the archive name.
    return .{ .images = images, .source = "", .arena = arena };
}

/// The parent-directory portion of `path` (everything before the last '/'),
/// or "" if there is none. POSIX-only; the app runs on macOS/Linux.
// Find the last path separator, recognizing both '/' and '\\' so Windows paths
// (which arrive with backslashes from the native file dialog) split correctly.
fn lastSep(path: []const u8) ?usize {
    var idx: ?usize = null;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') idx = i;
    }
    return idx;
}

fn dirname(path: []const u8) []const u8 {
    const i = lastSep(path) orelse return "";
    return if (i == 0) path[0..1] else path[0..i];
}

/// Derive a renderable disk label from a basename (a real on-disk path's
/// basename, or the UTF-8 cache name recovered via stripIndexPrefix): the name
/// itself, or "Disk N" (1-based) when nothing meaningful remains (e.g. an
/// extension-only label). The name is already UTF-8 and filesystem-safe, so it
/// is used verbatim — Japanese names render as-is with the bundled font.
fn displayName(a: std.mem.Allocator, raw: []const u8, index: usize) ![:0]const u8 {
    if (raw.len == 0 or hasBlankStem(raw))
        return std.fmt.allocPrintSentinel(a, "Disk {d}", .{index + 1}, 0);
    return a.dupeZ(u8, raw);
}

/// Derive a renderable source label (archive/folder name) from a real path's
/// basename — used verbatim (UTF-8) — falling back to `fallback` when empty.
fn displaySource(a: std.mem.Allocator, raw: []const u8, fallback: []const u8) ![:0]const u8 {
    return a.dupeZ(u8, if (raw.len == 0) fallback else raw);
}

/// Drop the "<NNNN>_" extraction prefix that unpackImages prepends, recovering
/// the (UTF-8, filesystem-safe) original basename. Returns the input unchanged
/// if it lacks the prefix (e.g. plain on-disk images never archive-extracted).
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

test "sanitizeFsName — keeps UTF-8, drops only unsafe bytes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("GAME_A.FDI", sanitizeFsName(&buf, "GAME_A.FDI"));
    try testing.expectEqualStrings("Disk 1.fdi", sanitizeFsName(&buf, "Disk 1.fdi"));
    // UTF-8 (Japanese) bytes are preserved verbatim.
    try testing.expectEqualStrings("ゲーム.fdi", sanitizeFsName(&buf, "ゲーム.fdi"));
    // Path separators, control chars, and Windows-illegal chars are dropped.
    try testing.expectEqualStrings("ab.fdi", sanitizeFsName(&buf, "a/b\t.f*di?"));
}

test "decodeName — CP932 decoded, valid UTF-8 passed through" {
    var buf: [64]u8 = undefined;
    // Already valid UTF-8 → returned unchanged.
    try testing.expectEqualStrings("ゲーム.fdi", decodeName(&buf, "ゲーム.fdi"));
    try testing.expectEqualStrings("GAME.FDI", decodeName(&buf, "GAME.FDI"));
    // CP932 (Shift-JIS) bytes for 金庫 → UTF-8.
    try testing.expectEqualStrings("金庫", decodeName(&buf, "\x8b\xe0\x8c\xc9"));
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

test "dirname — parent directory of a path" {
    try testing.expectEqualStrings("/a/b", dirname("/a/b/c.fdi"));
    try testing.expectEqualStrings("/", dirname("/c.fdi"));
    try testing.expectEqualStrings("", dirname("c.fdi"));
    // Windows paths arrive with backslashes from the native file dialog.
    try testing.expectEqualStrings("C:\\games", dirname("C:\\games\\disk.fdi"));
    try testing.expectEqualStrings("\\", dirname("\\disk.fdi"));
}

test "displayName — UTF-8 kept, blank stem falls back to Disk N" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("GAME_A.FDI", try displayName(a, "GAME_A.FDI", 0));
    // Japanese (UTF-8) names are kept verbatim.
    try testing.expectEqualStrings("ゲーム.fdi", try displayName(a, "ゲーム.fdi", 0));
    // Extension-only label (nothing meaningful precedes the dot) → "Disk N".
    try testing.expectEqualStrings("Disk 3", try displayName(a, ".fdi", 2));
    try testing.expectEqualStrings("Disk 1", try displayName(a, "", 0));
}

test "displaySource — UTF-8 name or fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("GAME.ZIP", try displaySource(a, "GAME.ZIP", "Archive"));
    try testing.expectEqualStrings("ゲーム集", try displaySource(a, "ゲーム集", "Folder"));
    try testing.expectEqualStrings("Folder", try displaySource(a, "", "Folder"));
}
