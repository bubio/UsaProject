const std = @import("std");
const testing = std.testing;

// Externs from src/np2_path.c — kept narrow to avoid pulling in NP2kai globals.
extern fn np2_set_datadir(dir: [*:0]const u8) void;
extern fn file_getcd(path: ?[*:0]const u8) [*:0]u8;
extern fn file_catname(path: [*:0]u8, name: [*:0]const u8, maxlen: c_int) void;
extern fn file_setcd(exepath: [*:0]const u8) void;
extern fn file_cutname(path: [*:0]u8) void;
extern fn file_getname(path: [*:0]const u8) [*:0]u8;
extern fn file_getext(path: [*:0]const u8) [*:0]u8;
extern fn np2_path_debug_curpath() [*:0]const u8;
extern fn np2_path_debug_reset() void;

fn cstr(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}

test "np2_set_datadir — appends trailing slash if missing" {
    np2_path_debug_reset();
    np2_set_datadir("/tmp/data");
    try testing.expectEqualStrings("/tmp/data/", cstr(np2_path_debug_curpath()));
}

test "np2_set_datadir — keeps existing trailing slash" {
    np2_path_debug_reset();
    np2_set_datadir("/tmp/data/");
    try testing.expectEqualStrings("/tmp/data/", cstr(np2_path_debug_curpath()));
}

test "np2_set_datadir — empty input is ignored" {
    np2_path_debug_reset();
    np2_set_datadir("");
    try testing.expectEqualStrings("./", cstr(np2_path_debug_curpath()));
}

test "file_getcd — appends filename to data dir" {
    np2_path_debug_reset();
    np2_set_datadir("/tmp/data");
    const result = file_getcd("FONT.ROM");
    try testing.expectEqualStrings("/tmp/data/FONT.ROM", cstr(result));
}

test "file_getcd — second call overwrites the filename slot" {
    np2_path_debug_reset();
    np2_set_datadir("/tmp/data");
    _ = file_getcd("first.rom");
    const result = file_getcd("second.rom");
    try testing.expectEqualStrings("/tmp/data/second.rom", cstr(result));
}

test "file_catname — concatenates to end of string" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..5], "/foo/");
    buf[5] = 0;
    file_catname(@ptrCast(&buf), "bar.rom", buf.len);
    try testing.expectEqualStrings("/foo/bar.rom", cstr(@ptrCast(&buf)));
}

test "file_catname — repeated calls do NOT accumulate junk (the original bug)" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..5], "/foo/");
    buf[5] = 0;
    file_catname(@ptrCast(&buf), "kanji1.rom", buf.len);
    // The bug we hit before: subsequent file_catname after file_cutname
    // appending additional names without cutting first should NOT silently
    // produce "kanji1.romkanji2.rom" if the caller properly resets.
    file_cutname(@ptrCast(&buf));
    file_catname(@ptrCast(&buf), "kanji2.rom", buf.len);
    try testing.expectEqualStrings("/foo/kanji2.rom", cstr(@ptrCast(&buf)));
}

test "file_cutname — erases the filename portion" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..12], "/foo/bar.rom");
    buf[12] = 0;
    file_cutname(@ptrCast(&buf));
    try testing.expectEqualStrings("/foo/", cstr(@ptrCast(&buf)));
}

test "file_getname — returns ptr after last separator" {
    const got = file_getname("/foo/bar/baz.rom");
    try testing.expectEqualStrings("baz.rom", cstr(got));
}

test "file_getname — no separator returns the original" {
    const got = file_getname("plain.rom");
    try testing.expectEqualStrings("plain.rom", cstr(got));
}

test "file_getext — returns extension after last dot" {
    const got = file_getext("/foo/bar.rom");
    try testing.expectEqualStrings("rom", cstr(got));
}

test "file_getext — no extension returns empty string (not NULL)" {
    const got = file_getext("/foo/bar");
    try testing.expectEqualStrings("", cstr(got));
}

test "file_setcd — sets directory portion from exe path" {
    np2_path_debug_reset();
    file_setcd("/opt/app/bin/exe");
    const result = file_getcd("config.ini");
    try testing.expectEqualStrings("/opt/app/bin/config.ini", cstr(result));
}
