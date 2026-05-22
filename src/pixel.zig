const std = @import("std");

/// Convert a single RGB565 pixel to RGBA8 (ABGR memory layout: 0xAABBGGRR).
pub fn rgb565ToRgba8(px: u16) u32 {
    const r5: u32 = (px >> 11) & 0x1f;
    const g6: u32 = (px >> 5) & 0x3f;
    const b5: u32 = px & 0x1f;
    const r8: u32 = (r5 << 3) | (r5 >> 2);
    const g8: u32 = (g6 << 2) | (g6 >> 4);
    const b8: u32 = (b5 << 3) | (b5 >> 2);
    return 0xFF000000 | (b8 << 16) | (g8 << 8) | r8;
}

/// Bulk convert an RGB565 framebuffer slice into an RGBA8 buffer of the same length.
pub fn rgb565BufferToRgba8(dst: []u32, src: []const u16) void {
    std.debug.assert(dst.len == src.len);
    for (src, 0..) |px, i| {
        dst[i] = rgb565ToRgba8(px);
    }
}

test "rgb565ToRgba8 — black" {
    try std.testing.expectEqual(@as(u32, 0xFF000000), rgb565ToRgba8(0x0000));
}

test "rgb565ToRgba8 — white" {
    // 0xFFFF in RGB565: R=0x1F G=0x3F B=0x1F → all expand to 0xFF.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), rgb565ToRgba8(0xFFFF));
}

test "rgb565ToRgba8 — pure red" {
    // R=0x1F G=0 B=0 → 0xF800 in RGB565 → ABGR 0xFF0000FF.
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), rgb565ToRgba8(0xF800));
}

test "rgb565ToRgba8 — pure green" {
    // R=0 G=0x3F B=0 → 0x07E0 → ABGR 0xFF00FF00.
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), rgb565ToRgba8(0x07E0));
}

test "rgb565ToRgba8 — pure blue" {
    // R=0 G=0 B=0x1F → 0x001F → ABGR 0xFFFF0000.
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), rgb565ToRgba8(0x001F));
}

test "rgb565ToRgba8 — preserves alpha=0xFF" {
    // No matter the input, alpha must always be 0xFF.
    var i: u32 = 0;
    while (i < 0x10000) : (i += 137) {
        const out = rgb565ToRgba8(@intCast(i));
        try std.testing.expectEqual(@as(u32, 0xFF000000), out & 0xFF000000);
    }
}

test "rgb565BufferToRgba8 — converts each pixel" {
    const src = [_]u16{ 0x0000, 0xFFFF, 0xF800, 0x07E0, 0x001F };
    var dst: [5]u32 = undefined;
    rgb565BufferToRgba8(&dst, &src);
    try std.testing.expectEqual(@as(u32, 0xFF000000), dst[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), dst[1]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), dst[2]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), dst[3]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), dst[4]);
}
