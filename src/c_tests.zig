// Aggregator for tests that depend on C headers/linkage.
test {
    _ = @import("path_test.zig");
    _ = @import("input.zig");
}
