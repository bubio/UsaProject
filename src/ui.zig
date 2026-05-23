const std = @import("std");
const sokol = @import("sokol");
const sdtx = sokol.debugtext;

pub const MENU_HEIGHT: u32 = 20;
pub const STATUS_HEIGHT: u32 = 20;

pub const State = struct {
    fps: f32 = 0.0,
    cpu_mhz: f32 = 0.0,
    fdd_access: [4]bool = .{ false, false, false, false },
};

pub fn setup() void {
    var desc: sdtx.Desc = .{
        .logger = .{ .func = sokol.log.func },
    };
    desc.fonts[0] = sdtx.fontKc853();
    sdtx.setup(desc);
}

pub fn shutdown() void {
    sdtx.shutdown();
}

pub fn draw(win_w: u32, win_h: u32, st: State) void {
    sdtx.canvas(@floatFromInt(win_w), @floatFromInt(win_h));
    sdtx.font(0);

    // Menu bar (top row, y=1 cell ≈ pixel 8..16, sits inside the 20px reserved area).
    sdtx.color3b(0xE0, 0xE0, 0xE0);
    sdtx.pos(1.0, 1.0);
    sdtx.puts("File  System  Help");

    // Status bar (bottom).
    const status_row: f32 = @as(f32, @floatFromInt(win_h - STATUS_HEIGHT + 6)) / 8.0;
    sdtx.color3b(0xC0, 0xC0, 0xC0);
    sdtx.pos(1.0, status_row);

    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, "FPS:{d:>5.1}  CPU:{d:>5.1}MHz  FD: {s}{s}{s}{s}", .{
        st.fps,
        st.cpu_mhz,
        lamp(st.fdd_access[0]),
        lamp(st.fdd_access[1]),
        lamp(st.fdd_access[2]),
        lamp(st.fdd_access[3]),
    }) catch return;
    sdtx.puts(line);
}

fn lamp(on: bool) []const u8 {
    return if (on) "*" else "-";
}
