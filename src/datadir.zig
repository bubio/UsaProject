const std = @import("std");
const builtin = @import("builtin");

pub const app_name = "UsaProject";

pub const Error = error{
    NoHome,
    UnsupportedOS,
    OutOfMemory,
};

/// Resolve the OS-conventional per-user data directory for this app.
/// Takes the user's home directory and target OS as parameters so the
/// function is pure and unit-testable.
///
/// Caller owns the returned slice.
pub fn resolve(allocator: std.mem.Allocator, home: []const u8, os: std.Target.Os.Tag) Error![:0]u8 {
    return switch (os) {
        .macos => std.fmt.allocPrintSentinel(allocator, "{s}/Library/Application Support/{s}", .{ home, app_name }, 0) catch error.OutOfMemory,
        .linux => std.fmt.allocPrintSentinel(allocator, "{s}/.local/share/{s}", .{ home, app_name }, 0) catch error.OutOfMemory,
        else => error.UnsupportedOS,
    };
}

/// Resolve using the current host OS and HOME env var (via libc getenv).
pub fn resolveDefault(allocator: std.mem.Allocator) Error![:0]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_ptr);
    return resolve(allocator, home, builtin.os.tag);
}

/// Make sure the directory exists. Idempotent.
/// `path` must be null-terminated (use [:0]const u8 in practice).
pub fn ensureExists(path: [:0]const u8) !void {
    const rc = std.c.mkdir(path.ptr, 0o755);
    if (rc == 0) return;
    // Already-exists is the only error we tolerate.
    const errno = std.c._errno().*;
    const EEXIST = 17;
    if (errno == EEXIST) return;
    return error.MkdirFailed;
}

test "resolve — macOS layout" {
    const got = try resolve(std.testing.allocator, "/Users/alice", .macos);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/Users/alice/Library/Application Support/UsaProject", got);
}

test "resolve — Linux layout" {
    const got = try resolve(std.testing.allocator, "/home/bob", .linux);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/home/bob/.local/share/UsaProject", got);
}

test "resolve — unsupported OS" {
    try std.testing.expectError(error.UnsupportedOS, resolve(std.testing.allocator, "/tmp", .freebsd));
}

test "resolve — sentinel terminated" {
    const got = try resolve(std.testing.allocator, "/x", .macos);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(u8, 0), got.ptr[got.len]);
}
