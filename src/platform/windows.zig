const std = @import("std");

pub const shader_vs_source = @embedFile("shaders/blit.vs.hlsl");
pub const shader_fs_source = @embedFile("shaders/blit.fs.hlsl");
pub const shader_entry = "main";

pub const data_dir_template = "{s}/AppData/Local/{s}";

pub fn getHome() ?[*:0]const u8 {
    return std.c.getenv("USERPROFILE");
}

pub fn monotonicNs() i128 {
    const windows = std.os.windows;
    var qpf: windows.LARGE_INTEGER = undefined;
    _ = windows.ntdll.RtlQueryPerformanceFrequency(&qpf);
    var qpc: windows.LARGE_INTEGER = undefined;
    _ = windows.ntdll.RtlQueryPerformanceCounter(&qpc);
    const f: i128 = @intCast(qpf);
    const c: i128 = @intCast(qpc);
    return @divTrunc(c * std.time.ns_per_s, f);
}
