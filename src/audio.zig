const std = @import("std");

/// NP2kaiのPCMデータ (SINT32だが実質16bit範囲) を sokol_audio用の f32 に変換する
pub fn convertPcmToFloat(dst: []f32, src: [*]const i32, samples: usize) void {
    for (0..samples) |i| {
        // ステレオなので * 2
        // NP2kaiの音声出力は概ね 16bit 範囲 (-32768 to 32767)
        dst[i * 2 + 0] = @as(f32, @floatFromInt(src[i * 2 + 0])) / 32768.0;
        dst[i * 2 + 1] = @as(f32, @floatFromInt(src[i * 2 + 1])) / 32768.0;
    }
}

test "convertPcmToFloat handles boundary values" {
    var dst = [_]f32{0.0} ** 6;
    const src = [_]i32{
        32767, -32768, // Max / Min
        0,     1,      // Zero / Small positive
        -1,    16384,  // Small negative / Half max
    };

    convertPcmToFloat(&dst, &src, 3);

    const eps = 0.0001;
    try std.testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), dst[0], eps);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dst[1], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dst[2], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 32768.0), dst[3], eps);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0 / 32768.0), dst[4], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dst[5], eps);
}
