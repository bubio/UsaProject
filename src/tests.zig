// Aggregator for pure-Zig unit tests.
test {
    _ = @import("pixel.zig");
    _ = @import("audio.zig");
    _ = @import("platform.zig");
    _ = @import("cli.zig");
    _ = @import("frame_scheduler.zig");
    _ = @import("ui.zig");
}
