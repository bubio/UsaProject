const std = @import("std");
const sapp = @import("sokol").app;
const cz = @import("c.zig");
const nk = @import("nk.zig");
const ui = @import("ui.zig");

/// Convert a sokol app keycode to a PC-98 NKEY code.
/// Returns null if the key has no direct mapping or is unmapped.
/// Respects the KEYBOARD setting (0=JP106, 1=US101).
pub fn mapKeycode(code: sapp.Keycode) ?u8 {
    return mapKeycodeLayout(code, cz.usa_get_keyboard() != 0);
}

fn mapKeycodeLayout(code: sapp.Keycode, is_101: bool) ?u8 {
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
        .EQUAL => 0x0c,
        .BACKSLASH => 0x0d,
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
        .LEFT_BRACKET => if (is_101) 0x1b else 0x1a, // 101: [, 106: @
        .RIGHT_BRACKET => if (is_101) 0x28 else 0x1b, // 101: ], 106: [
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
        .APOSTROPHE => 0x27, // PC-98 : *
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
        .SPACE => 0x34,
        .PAGE_UP => 0x36,
        .PAGE_DOWN => 0x37,
        .INSERT => 0x38,
        .DELETE => 0x39,
        .UP => 0x3a,
        .LEFT => 0x3b,
        .RIGHT => 0x3c,
        .DOWN => 0x3d,
        .HOME => 0x3e,
        .END => 0x3f,
        .KP_SUBTRACT => 0x40,
        .KP_DIVIDE => 0x41,
        .KP_7 => 0x42,
        .KP_8 => 0x43,
        .KP_9 => 0x44,
        .KP_MULTIPLY => 0x45,
        .KP_4 => 0x46,
        .KP_5 => 0x47,
        .KP_6 => 0x48,
        .KP_ADD => 0x49,
        .KP_1 => 0x4a,
        .KP_2 => 0x4b,
        .KP_3 => 0x4c,
        .KP_EQUAL => 0x4d,
        .KP_0 => 0x4e,
        .KP_DECIMAL => 0x50,
        .KP_ENTER => 0x1c,
        .GRAVE_ACCENT => if (is_101) 0x1a else 0x51, // 101: @, 106: NFER
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
        .LEFT_SHIFT, .RIGHT_SHIFT => 0x70,
        .CAPS_LOCK => 0x71,
        .LEFT_CONTROL => 0x74,
        .RIGHT_CONTROL => 0x73, // GRPH
        .LEFT_ALT => 0x51, // NFER
        .RIGHT_ALT => 0x35, // XFER
        else => null,
    };
}

var mouse_captured: bool = false;

// Track which PC-98 keys are currently held on the host side,
// so we can re-send them after a reset (which clears keystat).
var keys_held: [128]bool = [_]bool{false} ** 128;

fn resendHeldKeys() void {
    for (0..128) |i| {
        if (keys_held[i]) {
            cz.keystat_keydown(@intCast(i));
        }
    }
}

fn captureMouse() void {
    if (!mouse_captured) {
        mouse_captured = true;
        sapp.lockMouse(true);
    }
}

fn releaseMouse() void {
    if (mouse_captured) {
        mouse_captured = false;
        sapp.lockMouse(false);
    }
}

pub fn isMouseCaptured() bool {
    return mouse_captured;
}

pub fn handleEvent(ev: [*c]const sapp.Event) callconv(.c) void {
    const event = ev.*;

    // Host shortcuts — always active regardless of Nuklear/mouse state
    if (event.type == .KEY_DOWN) {
        if (event.key_code == .ESCAPE) {
            if (mouse_captured) {
                releaseMouse();
                return;
            }
        }

        const is_super = (event.modifiers & sapp.modifier_super) != 0;
        const is_ctrl = (event.modifiers & sapp.modifier_ctrl) != 0;
        const cmd_or_ctrl = is_super or is_ctrl;

        if (cmd_or_ctrl) {
            releaseMouse();
            switch (event.key_code) {
                .R => {
                    cz.pccore_reset();
                    resendHeldKeys();
                    return;
                },
                .Q => {
                    sapp.requestQuit();
                    return;
                },
                else => {},
            }
        }
    }

    // When mouse is captured, route directly to emulator (skip Nuklear)
    if (mouse_captured) {
        switch (event.type) {
            .MOUSE_MOVE => {
                cz.usa_mouse_move(@intFromFloat(event.mouse_dx), @intFromFloat(event.mouse_dy));
            },
            .MOUSE_DOWN => {
                cz.usa_mouse_btn_down(if (event.mouse_button == .LEFT) 1 else 0);
            },
            .MOUSE_UP => {
                cz.usa_mouse_btn_up(if (event.mouse_button == .LEFT) 1 else 0);
            },
            .KEY_DOWN => {
                if (mapKeycode(event.key_code)) |nkey| {
                    keys_held[nkey] = true;
                    cz.keystat_keydown(nkey);
                }
            },
            .KEY_UP => {
                if (mapKeycode(event.key_code)) |nkey| {
                    keys_held[nkey] = false;
                    cz.keystat_keyup(nkey);
                }
            },
            else => {},
        }
        return;
    }

    // Let Nuklear handle UI events (menu bar, status bar, dialogs)
    if (nk.handleEvent(@ptrCast(ev))) return;

    // Uncaptured click in emulator area → capture mouse
    if (event.type == .MOUSE_DOWN) {
        const my: i32 = @intFromFloat(event.mouse_y);
        const emu_top: i32 = @intCast(ui.MENU_HEIGHT);
        const emu_bot: i32 = @intCast(sapp.height() - @as(c_int, @intCast(ui.STATUS_HEIGHT)));
        if (my >= emu_top and my < emu_bot) {
            captureMouse();
            cz.usa_mouse_btn_down(if (event.mouse_button == .LEFT) 1 else 0);
        }
        return;
    }

    // Pass keyboard to PC-98
    if (event.type == .KEY_DOWN) {
        if (mapKeycode(event.key_code)) |nkey| {
            keys_held[nkey] = true;
            cz.keystat_keydown(nkey);
        }
    } else if (event.type == .KEY_UP) {
        if (mapKeycode(event.key_code)) |nkey| {
            keys_held[nkey] = false;
            cz.keystat_keyup(nkey);
        }
    }
}

test "common keys identical for both layouts" {
    for ([_]bool{ false, true }) |is_101| {
        try std.testing.expectEqual(@as(?u8, 0x00), mapKeycodeLayout(.ESCAPE, is_101));
        try std.testing.expectEqual(@as(?u8, 0x34), mapKeycodeLayout(.SPACE, is_101));
        try std.testing.expectEqual(@as(?u8, 0x1c), mapKeycodeLayout(.ENTER, is_101));
        try std.testing.expectEqual(@as(?u8, 0x1d), mapKeycodeLayout(.A, is_101));
        try std.testing.expectEqual(@as(?u8, 0x29), mapKeycodeLayout(.Z, is_101));
        try std.testing.expectEqual(@as(?u8, 0x01), mapKeycodeLayout(._1, is_101));
        try std.testing.expectEqual(@as(?u8, 0x62), mapKeycodeLayout(.F1, is_101));
        try std.testing.expectEqual(@as(?u8, 0x27), mapKeycodeLayout(.APOSTROPHE, is_101));
        try std.testing.expectEqual(@as(?u8, null), mapKeycodeLayout(.INVALID, is_101));
    }
}

test "modifiers match NP2kai reference" {
    for ([_]bool{ false, true }) |is_101| {
        try std.testing.expectEqual(@as(?u8, 0x70), mapKeycodeLayout(.LEFT_SHIFT, is_101));
        try std.testing.expectEqual(@as(?u8, 0x74), mapKeycodeLayout(.LEFT_CONTROL, is_101));
        try std.testing.expectEqual(@as(?u8, 0x73), mapKeycodeLayout(.RIGHT_CONTROL, is_101));
        try std.testing.expectEqual(@as(?u8, 0x51), mapKeycodeLayout(.LEFT_ALT, is_101));
        try std.testing.expectEqual(@as(?u8, 0x35), mapKeycodeLayout(.RIGHT_ALT, is_101));
    }
}

test "106 layout-specific keys" {
    try std.testing.expectEqual(@as(?u8, 0x1a), mapKeycodeLayout(.LEFT_BRACKET, false));
    try std.testing.expectEqual(@as(?u8, 0x1b), mapKeycodeLayout(.RIGHT_BRACKET, false));
    try std.testing.expectEqual(@as(?u8, 0x51), mapKeycodeLayout(.GRAVE_ACCENT, false));
}

test "101 layout-specific keys" {
    try std.testing.expectEqual(@as(?u8, 0x1b), mapKeycodeLayout(.LEFT_BRACKET, true));
    try std.testing.expectEqual(@as(?u8, 0x28), mapKeycodeLayout(.RIGHT_BRACKET, true));
    try std.testing.expectEqual(@as(?u8, 0x1a), mapKeycodeLayout(.GRAVE_ACCENT, true));
}
