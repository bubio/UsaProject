const std = @import("std");

pub const shader_vs_source = @embedFile("shaders/blit.vs.glsl");
pub const shader_fs_source = @embedFile("shaders/blit.fs.glsl");
pub const shader_entry = "main";

pub const data_dir_template = "{s}/.local/share/{s}";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("HOME");
}

pub fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
