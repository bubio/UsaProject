const std = @import("std");

const c = @cImport({
    @cInclude("nfd.h");
});

pub const Error = error{InitFailed, DialogFailed, OutOfMemory};

const NFD_ERROR: c_int = 0;
const NFD_OKAY: c_int = 1;
const NFD_CANCEL: c_int = 2;

var initialized: bool = false;

fn ensureInit() Error!void {
    if (initialized) return;
    if (c.NFD_Init() != NFD_OKAY) return Error.InitFailed;
    initialized = true;
}

pub fn deinit() void {
    if (initialized) {
        c.NFD_Quit();
        initialized = false;
    }
}

pub const Filter = struct {
    name: [:0]const u8, // e.g. "Disk Images"
    spec: [:0]const u8, // e.g. "fdi,d88,hdm,hdi"
};

/// Show a "Open File" dialog. Returns the selected path (caller owns), or
/// `null` if the user cancelled. The returned slice is allocated with
/// `allocator` and must be freed by the caller.
pub fn openDialog(allocator: std.mem.Allocator, filters: []const Filter) Error!?[:0]u8 {
    try ensureInit();

    var stack_items: [8]c.nfdu8filteritem_t = undefined;
    const n = @min(filters.len, stack_items.len);
    for (filters[0..n], 0..) |f, i| {
        stack_items[i] = .{ .name = f.name.ptr, .spec = f.spec.ptr };
    }

    var out_path: [*c]c.nfdu8char_t = null;
    const filter_ptr: [*c]const c.nfdu8filteritem_t = if (n > 0) &stack_items[0] else null;
    const rc = c.NFD_OpenDialogU8(&out_path, filter_ptr, @intCast(n), null);

    switch (rc) {
        NFD_OKAY => {
            defer c.NFD_FreePathU8(out_path);
            const slice = std.mem.span(out_path);
            const owned = allocator.allocSentinel(u8, slice.len, 0) catch return Error.OutOfMemory;
            @memcpy(owned, slice);
            return owned;
        },
        NFD_CANCEL => return null,
        else => return Error.DialogFailed,
    }
}
