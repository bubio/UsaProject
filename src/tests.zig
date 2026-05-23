// Aggregator for pure-Zig unit tests.
test {
    _ = @import("pixel.zig");
    _ = @import("datadir.zig");
    _ = @import("cli.zig");
    _ = @import("frame_scheduler.zig");
}
