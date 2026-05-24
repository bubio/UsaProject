const std = @import("std");
const builtin = @import("builtin");

pub const macos = @import("platform/macos.zig");
pub const linux = @import("platform/linux.zig");
pub const windows = @import("platform/windows.zig");

pub const os = switch (builtin.os.tag) {
    .macos => macos,
    .linux => linux,
    .windows => windows,
    else => @compileError("unsupported OS"),
};

pub const app_name = "UsaProject";

pub const Error = error{
    NoHome,
    OutOfMemory,
};

pub fn resolveDataDir(allocator: std.mem.Allocator) Error![:0]u8 {
    const home_ptr = os.getHome() orelse return error.NoHome;
    const home = std.mem.span(home_ptr);
    return std.fmt.allocPrintSentinel(allocator, os.data_dir_template, .{ home, app_name }, 0) catch error.OutOfMemory;
}

pub fn resolveDataDirFor(allocator: std.mem.Allocator, home: []const u8, comptime target: anytype) Error![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, target.data_dir_template, .{ home, app_name }, 0) catch error.OutOfMemory;
}

pub fn ensureExists(path: [:0]const u8) !void {
    const rc = std.c.mkdir(path.ptr, 0o755);
    if (rc == 0) return;
    const errno = std.c._errno().*;
    const EEXIST = 17;
    if (errno == EEXIST) return;
    return error.MkdirFailed;
}

test "resolveDataDirFor — macOS layout" {
    const got = try resolveDataDirFor(std.testing.allocator, "/Users/alice", macos);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/Users/alice/Library/Application Support/UsaProject", got);
}

test "resolveDataDirFor — Linux layout" {
    const got = try resolveDataDirFor(std.testing.allocator, "/home/bob", linux);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/home/bob/.local/share/UsaProject", got);
}

test "resolveDataDirFor — sentinel terminated" {
    const got = try resolveDataDirFor(std.testing.allocator, "/x", macos);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(u8, 0), got.ptr[got.len]);
}
