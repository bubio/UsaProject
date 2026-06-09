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

// Io implementation used to spawn the OS file-manager opener. Initialized from
// main() with the process environment so the child inherits PATH (to resolve
// the opener) and the desktop session vars (DISPLAY/DBUS) xdg-open needs.
var spawn_threaded: std.Io.Threaded = undefined;
var spawn_io: ?std.Io = null;

// Capture the process environment for later child spawns. Called once at
// startup. processSpawn builds the child's argv/environ blocks with this gpa,
// so it must be a real allocator (a failing one yields error.OutOfMemory).
pub fn initSpawn(environ: std.process.Environ) void {
    spawn_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = environ });
    spawn_io = spawn_threaded.io();
}

// Reveal the app's data directory (ROMs, disks, save states live here) in the
// OS file manager. The folder is created first so it always exists when opened,
// even on a fresh install. Best-effort: a spawn failure just returns the error
// for the caller to log.
pub fn openDataDir(allocator: std.mem.Allocator) !void {
    const io = spawn_io orelse return error.SpawnNotInitialized;
    const dir = try resolveDataDir(allocator);
    defer allocator.free(dir);
    ensureExists(dir) catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ os.open_cmd, dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // The opener launches the file manager and exits promptly; reap it so it
    // doesn't linger as a zombie.
    _ = child.wait(io) catch {};
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
