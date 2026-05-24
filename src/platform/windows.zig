const std = @import("std");

pub const shader_vs_source = @embedFile("shaders/blit.vs.glsl");
pub const shader_fs_source = @embedFile("shaders/blit.fs.glsl");
pub const shader_entry = "main";

pub const data_dir_template = "{s}/AppData/Local/{s}";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("USERPROFILE");
}
