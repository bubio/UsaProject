const std = @import("std");

pub const shader_vs_source = @embedFile("shaders/blit.vs.metal");
pub const shader_fs_source = @embedFile("shaders/blit.fs.metal");
pub const shader_entry = "_main";

pub const data_dir_template = "{s}/Library/Application Support/{s}";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("HOME");
}
