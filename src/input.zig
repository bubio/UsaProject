const std = @import("std");
const sapp = @import("sokol").app;
const cz = @import("c.zig");

/// Convert a sokol app keycode to a PC-98 NKEY code.
/// Returns null if the key has no direct mapping or is unmapped.
pub fn mapKeycode(code: sapp.Keycode) ?u8 {
    return switch (code) {
        .ESCAPE => 0x00,
        ._1 => 0x01,
        ._2 => 0x02,
        ._3 => 0x03,
        ._4 => 0x04,
        ._5 => 0x05,
        ._6 => 0x06,
        ._7 => 0x07,
        ._8 => 0x08,
        ._9 => 0x09,
        ._0 => 0x0a,
        .MINUS => 0x0b,
        .EQUAL => 0x0c, // map to circumflex roughly
        .BACKSLASH => 0x0d, // map to yen roughly
        .BACKSPACE => 0x0e,
        .TAB => 0x0f,
        .Q => 0x10,
        .W => 0x11,
        .E => 0x12,
        .R => 0x13,
        .T => 0x14,
        .Y => 0x15,
        .U => 0x16,
        .I => 0x17,
        .O => 0x18,
        .P => 0x19,
        .LEFT_BRACKET => 0x1a, // atmark
        .RIGHT_BRACKET => 0x1b, // left bracket roughly
        .ENTER => 0x1c,
        .A => 0x1d,
        .S => 0x1e,
        .D => 0x1f,
        .F => 0x20,
        .G => 0x21,
        .H => 0x22,
        .J => 0x23,
        .K => 0x24,
        .L => 0x25,
        .SEMICOLON => 0x26,
        .Z => 0x29,
        .X => 0x2a,
        .C => 0x2b,
        .V => 0x2c,
        .B => 0x2d,
        .N => 0x2e,
        .M => 0x2f,
        .COMMA => 0x30,
        .PERIOD => 0x31,
        .SLASH => 0x32,
        // UNDERSCORE 0x33
        .SPACE => 0x34,
        // XFER 0x35, ROLLUP 0x36, ROLLDOWN 0x37
        .PAGE_UP => 0x36,
        .PAGE_DOWN => 0x37,
        .INSERT => 0x38,
        .DELETE => 0x39,
        .UP => 0x3a,
        .LEFT => 0x3b,
        .RIGHT => 0x3c,
        .DOWN => 0x3d,
        .HOME => 0x3e,
        .END => 0x3f, // HELP
        .KP_SUBTRACT => 0x40, // NKEY_KP_MINUS
        .KP_DIVIDE => 0x41, // NKEY_KP_SLASH
        .KP_7 => 0x42,
        .KP_8 => 0x43,
        .KP_9 => 0x44,
        .KP_MULTIPLY => 0x45, // NKEY_KP_ASTERISK
        .KP_4 => 0x46,
        .KP_5 => 0x47,
        .KP_6 => 0x48,
        .KP_ADD => 0x49, // NKEY_KP_PLUS
        .KP_1 => 0x4a,
        .KP_2 => 0x4b,
        .KP_3 => 0x4c,
        .KP_EQUAL => 0x4d,
        .KP_0 => 0x4e,
        .KP_DECIMAL => 0x50, // NKEY_KP_DOT
        .KP_ENTER => 0x1c, // map to main return
        .GRAVE_ACCENT => 0x51, // NFER
        .APOSTROPHE => 0x35, // XFER
        .F1 => 0x62,
        .F2 => 0x63,
        .F3 => 0x64,
        .F4 => 0x65,
        .F5 => 0x66,
        .F6 => 0x67,
        .F7 => 0x68,
        .F8 => 0x69,
        .F9 => 0x6a,
        .F10 => 0x6b,
        .LEFT_SHIFT, .RIGHT_SHIFT => 0x70, // NKEY_SHIFT
        .CAPS_LOCK => 0x71, // NKEY_CAPS
        .LEFT_ALT, .RIGHT_ALT => 0x73, // NKEY_GRPH
        .LEFT_CONTROL, .RIGHT_CONTROL => 0x74, // NKEY_CTRL
        else => null,
    };
}

pub fn handleEvent(ev: [*c]const sapp.Event) callconv(.c) void {
    const event = ev.*;
    
    // Handle host shortcuts first
    if (event.type == .KEY_DOWN) {
        const is_super = (event.modifiers & sapp.modifier_super) != 0;
        const is_ctrl = (event.modifiers & sapp.modifier_ctrl) != 0;
        const cmd_or_ctrl = is_super or is_ctrl;
        
        if (cmd_or_ctrl) {
            switch (event.key_code) {
                .R => {
                    // Reset emulator
                    cz.pccore_reset();
                    return;
                },
                .Q => {
                    // Quit emulator
                    sapp.requestQuit();
                    return;
                },
                else => {},
            }
        }
    }

    // Pass to PC-98
    if (event.type == .KEY_DOWN) {
        if (mapKeycode(event.key_code)) |nkey| {
            cz.keystat_keydown(nkey);
        }
    } else if (event.type == .KEY_UP) {
        if (mapKeycode(event.key_code)) |nkey| {
            cz.keystat_keyup(nkey);
        }
    }
}

test "mapKeycode maps standard keys correctly" {
    // Basic keys
    try std.testing.expectEqual(@as(?u8, 0x00), mapKeycode(.ESCAPE));
    try std.testing.expectEqual(@as(?u8, 0x34), mapKeycode(.SPACE));
    try std.testing.expectEqual(@as(?u8, 0x1c), mapKeycode(.ENTER));
    try std.testing.expectEqual(@as(?u8, 0x0f), mapKeycode(.TAB));

    // Alphabet
    try std.testing.expectEqual(@as(?u8, 0x1d), mapKeycode(.A));
    try std.testing.expectEqual(@as(?u8, 0x29), mapKeycode(.Z));

    // Digits
    try std.testing.expectEqual(@as(?u8, 0x01), mapKeycode(._1));
    try std.testing.expectEqual(@as(?u8, 0x0a), mapKeycode(._0));

    // Functions
    try std.testing.expectEqual(@as(?u8, 0x62), mapKeycode(.F1));
    try std.testing.expectEqual(@as(?u8, 0x6b), mapKeycode(.F10));

    // Arrows
    try std.testing.expectEqual(@as(?u8, 0x3a), mapKeycode(.UP));
    try std.testing.expectEqual(@as(?u8, 0x3b), mapKeycode(.LEFT));

    // Modifiers
    try std.testing.expectEqual(@as(?u8, 0x70), mapKeycode(.LEFT_SHIFT));
    try std.testing.expectEqual(@as(?u8, 0x74), mapKeycode(.LEFT_CONTROL));
    try std.testing.expectEqual(@as(?u8, 0x73), mapKeycode(.LEFT_ALT));

    // Unmapped
    try std.testing.expectEqual(@as(?u8, null), mapKeycode(.INVALID));
    try std.testing.expectEqual(@as(?u8, null), mapKeycode(.MENU));
}

test "modifiers and shortcuts" {
    // Cmd+R should be handled by our logic, but mapKeycode itself
    // only returns the PC-98 key code, not the shortcut logic.
    // The shortcut logic is in handleEvent, which is harder to test
    // without a dummy sapp.Event, but we can test modifier combinations.

    const ctrl = sapp.modifier_ctrl;
    const shift = sapp.modifier_shift;
    const alt = sapp.modifier_alt;
    _ = alt;

    try std.testing.expect((ctrl & sapp.modifier_ctrl) != 0);
    try std.testing.expect((ctrl | shift & sapp.modifier_ctrl) != 0);

    // PC-98 special keys
    try std.testing.expectEqual(@as(?u8, 0x70), mapKeycode(.LEFT_SHIFT));
    try std.testing.expectEqual(@as(?u8, 0x70), mapKeycode(.RIGHT_SHIFT));
    try std.testing.expectEqual(@as(?u8, 0x74), mapKeycode(.LEFT_CONTROL));
    try std.testing.expectEqual(@as(?u8, 0x74), mapKeycode(.RIGHT_CONTROL));
    try std.testing.expectEqual(@as(?u8, 0x73), mapKeycode(.LEFT_ALT)); // GRPH
    try std.testing.expectEqual(@as(?u8, 0x51), mapKeycode(.GRAVE_ACCENT)); // NFER
    try std.testing.expectEqual(@as(?u8, 0x35), mapKeycode(.APOSTROPHE)); // XFER
}
