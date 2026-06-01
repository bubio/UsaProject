//! Recently-opened disk image history for the FDD/HDD menus.
//!
//! Keeps a small most-recent-first list of the original paths the user opened
//! (a plain image, a .zip archive, or a folder member) per disk kind, so the
//! drive menus can offer them as one-click re-mount targets. Paths are stored
//! verbatim and re-fed through the normal open logic (ui.mountPath), so a
//! multi-disk archive re-opens its disk-selection modal just like a fresh open.
//!
//! The list is persisted to np2kai.cfg by config.zig (RecentFDD*/RecentHDD*).

const std = @import("std");
const cli = @import("cli.zig");

/// Max entries kept per kind.
pub const cap = 8;

const alloc = std.heap.page_allocator;

const List = struct {
    items: [cap]?[:0]u8 = .{null} ** cap,
    len: usize = 0,
};

var fdd: List = .{};
var hdd: List = .{};

fn listFor(kind: cli.DiskKind) *List {
    return switch (kind) {
        .fdd => &fdd,
        .hdd => &hdd,
        .archive => unreachable,
    };
}

// Index of an entry equal to `path`, if present.
fn indexOf(l: *const List, path: []const u8) ?usize {
    for (l.items[0..l.len], 0..) |e, i| {
        if (e) |s| if (std.mem.eql(u8, s, path)) return i;
    }
    return null;
}

/// Record a user-opened path as the most recent entry. Moves an existing match
/// to the front (dedup); otherwise inserts at the front and drops/free the
/// oldest entry once `cap` is exceeded. Allocation failure is silently ignored.
pub fn record(kind: cli.DiskKind, path: []const u8) void {
    const l = listFor(kind);

    if (indexOf(l, path)) |idx| {
        // Already present: rotate [0..idx] right so it becomes the front.
        const moved = l.items[idx].?;
        var i = idx;
        while (i > 0) : (i -= 1) l.items[i] = l.items[i - 1];
        l.items[0] = moved;
        return;
    }

    const dup = alloc.dupeZ(u8, path) catch return;

    if (l.len < cap) {
        l.len += 1;
    } else {
        // Full: free the entry about to fall off the end.
        if (l.items[cap - 1]) |old| alloc.free(old);
    }
    var i = l.len - 1;
    while (i > 0) : (i -= 1) l.items[i] = l.items[i - 1];
    l.items[0] = dup;
}

/// Append a path to the end, used when loading the saved order from config.
/// Skips duplicates and silently stops once full. Allocation failure ignored.
pub fn append(kind: cli.DiskKind, path: []const u8) void {
    const l = listFor(kind);
    if (l.len >= cap) return;
    if (indexOf(l, path) != null) return;
    const dup = alloc.dupeZ(u8, path) catch return;
    l.items[l.len] = dup;
    l.len += 1;
}

pub fn count(kind: cli.DiskKind) usize {
    return listFor(kind).len;
}

/// The i-th entry (0 = most recent). Caller must keep `i < count(kind)`.
pub fn at(kind: cli.DiskKind, i: usize) [:0]const u8 {
    return listFor(kind).items[i].?;
}

/// Free all entries; call at shutdown (after config.save has read them).
pub fn deinit() void {
    inline for (.{ &fdd, &hdd }) |l| {
        for (l.items[0..l.len]) |e| {
            if (e) |s| alloc.free(s);
        }
        l.* = .{};
    }
}
