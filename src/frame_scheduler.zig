const std = @import("std");

/// 1 / 59.94 Hz (PC-98 standard vertical sync) in nanoseconds.
/// Using NTSC-ish 59.94 instead of exact 60 keeps the long-run drift
/// against actual PC-98 hardware bounded.
pub const pc98_frame_ns: i128 = 16_683_333;

/// Cap how many catch-up emulator frames we run in a single host frame.
/// Prevents a death spiral if the host stalls (e.g., laptop wake from sleep).
pub const max_catchup_frames: u32 = 4;

pub const Decision = struct {
    /// Number of pccore_exec calls to run *this* host frame.
    /// 0 means we're ahead of schedule — skip emulation, just redraw.
    frames: u32,
    /// Updated "last emulated" timestamp the caller should store.
    new_last_ns: i128,
};

/// Compute how many PC-98 frames to advance given wall-clock time.
/// Pure function — no I/O — so it's unit-testable.
///
/// - `now_ns`: current wall clock (e.g. std.time.nanoTimestamp()).
/// - `last_ns`: timestamp of the last completed emulator frame, or 0 on
///   the very first call (treated as "one frame ago" so we run exactly 1).
pub fn decide(now_ns: i128, last_ns: i128) Decision {
    if (last_ns == 0) {
        // Bootstrap: pretend we last emulated exactly one frame ago, so
        // the very first host frame advances by 1.
        return .{ .frames = 1, .new_last_ns = now_ns };
    }

    const elapsed = now_ns - last_ns;
    if (elapsed < pc98_frame_ns) {
        // Host running faster than 60Hz (e.g., 120Hz display). Don't
        // advance the emu — just redraw the existing framebuffer.
        return .{ .frames = 0, .new_last_ns = last_ns };
    }

    const due_i128 = @divFloor(elapsed, pc98_frame_ns);
    if (due_i128 > @as(i128, max_catchup_frames)) {
        // Big stall — give up on catching up to avoid a spiral. Reset
        // the clock as if we just finished a single frame at `now_ns`.
        return .{ .frames = max_catchup_frames, .new_last_ns = now_ns };
    }

    const frames: u32 = @intCast(due_i128);
    return .{ .frames = frames, .new_last_ns = last_ns + due_i128 * pc98_frame_ns };
}

// ---------- tests ----------

const testing = std.testing;

test "decide — bootstrap runs exactly one frame" {
    const d = decide(1_000_000_000, 0);
    try testing.expectEqual(@as(u32, 1), d.frames);
    try testing.expectEqual(@as(i128, 1_000_000_000), d.new_last_ns);
}

test "decide — too early returns 0 frames, last unchanged" {
    const last: i128 = 1_000_000_000;
    const d = decide(last + pc98_frame_ns / 2, last);
    try testing.expectEqual(@as(u32, 0), d.frames);
    try testing.expectEqual(last, d.new_last_ns);
}

test "decide — exactly one frame elapsed runs 1" {
    const last: i128 = 1_000_000_000;
    const d = decide(last + pc98_frame_ns, last);
    try testing.expectEqual(@as(u32, 1), d.frames);
    try testing.expectEqual(last + pc98_frame_ns, d.new_last_ns);
}

test "decide — two frames elapsed runs 2" {
    const last: i128 = 1_000_000_000;
    const d = decide(last + 2 * pc98_frame_ns + 100, last);
    try testing.expectEqual(@as(u32, 2), d.frames);
    try testing.expectEqual(last + 2 * pc98_frame_ns, d.new_last_ns);
}

test "decide — huge stall caps at max_catchup and resets to now" {
    const last: i128 = 1_000_000_000;
    const now = last + 100 * pc98_frame_ns;
    const d = decide(now, last);
    try testing.expectEqual(max_catchup_frames, d.frames);
    try testing.expectEqual(now, d.new_last_ns);
}

test "decide — fractional progress accumulates correctly" {
    // Display at 90Hz (~11.1ms): every other frame should advance by 1.
    const host_ns: i128 = 11_111_111;
    var last: i128 = 1_000_000_000;
    var now: i128 = last;
    var total_frames: u32 = 0;
    var host_ticks: u32 = 0;
    while (host_ticks < 60) : (host_ticks += 1) {
        now += host_ns;
        const d = decide(now, last);
        total_frames += d.frames;
        last = d.new_last_ns;
    }
    // 60 ticks * 11.1ms = 666.6ms ≈ 40 PC-98 frames (40 * 16.68ms = 667.3ms).
    try testing.expect(total_frames >= 39 and total_frames <= 41);
}
