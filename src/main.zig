const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const saudio = sokol.audio;
const sglue = sokol.glue;
const cz = @import("c.zig");
const c = cz.c;
const pixel = @import("pixel.zig");
const datadir = @import("datadir.zig");
const cli = @import("cli.zig");
const scheduler = @import("frame_scheduler.zig");
const input = @import("input.zig");
const audio = @import("audio.zig");
const ui = @import("ui.zig");
const sdtx = sokol.debugtext;

const blit_vs_glsl = @embedFile("shaders/blit.vs.glsl");
const blit_fs_glsl = @embedFile("shaders/blit.fs.glsl");
const blit_vs_metal = @embedFile("shaders/blit.vs.metal");
const blit_fs_metal = @embedFile("shaders/blit.fs.metal");

const FB_WIDTH = 640;
const FB_HEIGHT = 400;
const WIN_WIDTH = FB_WIDTH;
const WIN_HEIGHT = FB_HEIGHT + ui.MENU_HEIGHT + ui.STATUS_HEIGHT;

// PC-98 framebuffer quad in NDC: leaves MENU_HEIGHT px at top and STATUS_HEIGHT px at bottom.
const FB_NDC_TOP: f32 = 1.0 - 2.0 * @as(f32, @floatFromInt(ui.MENU_HEIGHT)) / @as(f32, @floatFromInt(WIN_HEIGHT));
const FB_NDC_BOT: f32 = 1.0 - 2.0 * @as(f32, @floatFromInt(ui.MENU_HEIGHT + FB_HEIGHT)) / @as(f32, @floatFromInt(WIN_HEIGHT));

const State = struct {
    pipeline: sg.Pipeline = .{},
    bindings: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
    image: sg.Image = .{},
    view: sg.View = .{},
    sampler: sg.Sampler = .{},
};

var state: State = .{};
var fb_rgba: [FB_WIDTH * FB_HEIGHT]u32 = undefined;
var parsed_opts: ?cli.Options = null;
var last_emu_ns: i128 = 0;

// 音声バッファ（Zig側で変換用に使用）
var audio_buffer: [4096 * 2]f32 = undefined;

// Cから呼ばれる音声プッシュ関数
export fn zig_audio_push(pcm: [*]const i32, count: u32) void {
    const samples = @min(count, @as(u32, @intCast(audio_buffer.len / 2)));
    audio.convertPcmToFloat(&audio_buffer, pcm, samples);
    _ = saudio.push(&audio_buffer[0], @intCast(samples));
}

// FIFO に書き込み可能なフレーム数を返す。soundmng_sync 側で throttle に使う。
export fn zig_audio_writable() u32 {
    const w = saudio.expect();
    if (w <= 0) return 0;
    return @intCast(w);
}

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // sokol_audio 初期化
    saudio.setup(.{
        .sample_rate = 44100,
        .num_channels = 2,
        .logger = .{ .func = sokol.log.func },
    });

    ui.setup();

    setupDataDir();

    cz.pccore_init_config();
    if (parsed_opts) |opts| {
        if (opts.model) |m| cz.np2_set_model(m.ptr);
    }
    cz.pccore_init();
    cz.pccore_reset();
    if (parsed_opts) |opts| insertDisks(opts);

    state.image = sg.makeImage(.{
        .width = FB_WIDTH,
        .height = FB_HEIGHT,
        .pixel_format = .RGBA8,
        .usage = .{ .stream_update = true },
    });

    state.view = sg.makeView(.{
        .texture = .{ .image = state.image },
    });

    state.sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
    });

    const vertices = [_]f32{
        -1.0, FB_NDC_TOP, 0.5,   0.0, 0.0,
         1.0, FB_NDC_TOP, 0.5,   1.0, 0.0,
         1.0, FB_NDC_BOT, 0.5,   1.0, 1.0,
        -1.0, FB_NDC_BOT, 0.5,   0.0, 1.0,
    };
    state.bindings.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&vertices),
    });

    const indices = [_]u16{ 0, 1, 2,  0, 2, 3 };
    state.bindings.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = sg.asRange(&indices),
    });

    state.bindings.views[0] = state.view;
    state.bindings.samplers[0] = state.sampler;

    state.pipeline = sg.makePipeline(.{
        .shader = makeBlitShader(),
        .layout = .{
            .attrs = init: {
                var attrs: [16]sg.VertexAttrState = @splat(.{});
                attrs[0].format = .FLOAT3;
                attrs[1].format = .FLOAT2;
                break :init attrs;
            },
        },
        .index_type = .UINT16,
    });

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    };
}

fn insertDisks(opts: cli.Options) void {
    var fdd_drv: c_uint = 0;
    var hdd_drv: c_uint = 0;
    for (opts.disks) |d| switch (d.kind) {
        .fdd => {
            std.debug.print(">>> FDD{d}: {s}\n", .{ fdd_drv, d.path });
            cz.np2_insert_fdd(fdd_drv, d.path.ptr);
            fdd_drv += 1;
        },
        .hdd => {
            std.debug.print(">>> HDD{d}: {s}\n", .{ hdd_drv, d.path });
            cz.np2_insert_hdd(hdd_drv, d.path.ptr);
            hdd_drv += 1;
        },
    };
}

fn setupDataDir() void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const dir = datadir.resolveDefault(fba.allocator()) catch |err| {
        std.debug.print("!! could not resolve data dir: {s}\n", .{@errorName(err)});
        return;
    };
    datadir.ensureExists(dir) catch |err| {
        std.debug.print("!! could not create data dir '{s}': {s}\n", .{ dir, @errorName(err) });
        // Fall through — np2_set_datadir is still useful for read-only files.
    };
    std.debug.print(">>> data dir: {s}\n", .{dir});
    cz.np2_set_datadir(dir.ptr);
}

fn makeBlitShader() sg.Shader {
    const is_macos = (builtin.os.tag == .macos);
    return sg.makeShader(.{
        .vertex_func = .{
            .source = if (is_macos) blit_vs_metal else blit_vs_glsl,
        },
        .fragment_func = .{
            .entry = if (is_macos) "_main" else "main",
            .source = if (is_macos) blit_fs_metal else blit_fs_glsl,
        },
        .views = init: {
            var v: [32]sg.ShaderView = @splat(.{});
            v[0].texture = .{
                .stage = .FRAGMENT,
                .image_type = ._2D,
                .sample_type = .FLOAT,
                .msl_texture_n = 0,
            };
            break :init v;
        },
        .samplers = init: {
            var s: [12]sg.ShaderSampler = @splat(.{});
            s[0] = .{
                .stage = .FRAGMENT,
                .sampler_type = .FILTERING,
                .msl_sampler_n = 0,
            };
            break :init s;
        },
        .texture_sampler_pairs = init: {
            var p: [32]sg.ShaderTextureSamplerPair = @splat(.{});
            p[0] = .{
                .stage = .FRAGMENT,
                .view_slot = 0,
                .sampler_slot = 0,
                .glsl_name = "tex_smp",
            };
            break :init p;
        },
    });
}

export fn frame() void {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const now: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    const decision = scheduler.decide(now, last_emu_ns);
    last_emu_ns = decision.new_last_ns;

    if (decision.frames > 0) {
        // Catch-up frames: advance the emulator without triggering a redraw.
        var i: u32 = 1;
        while (i < decision.frames) : (i += 1) {
            cz.pccore_exec(false);
            cz.sound_sync();
        }
        // Final frame: this is the one whose framebuffer we display.
        cz.pccore_exec(true);
        cz.sound_sync();
        cz.scrndraw_redraw();
    }

    pixel.rgb565BufferToRgba8(&fb_rgba, cz.pc98_framebuffer[0 .. FB_WIDTH * FB_HEIGHT]);

    var img_data = sg.ImageData{};
    img_data.mip_levels[0] = sg.asRange(&fb_rgba);
    sg.updateImage(state.image, img_data);

    // Update UI overlay state.
    cz.usa_lamp_tick();
    const dt = sapp.frameDuration();
    const fps: f32 = if (dt > 0.0) @floatCast(1.0 / dt) else 0.0;
    ui.draw(WIN_WIDTH, WIN_HEIGHT, .{
        .fps = fps,
        .cpu_mhz = @floatCast(cz.usa_cpu_clock_mhz()),
        .fdd_access = .{
            cz.usa_fdd_lamp(0) != 0,
            cz.usa_fdd_lamp(1) != 0,
            cz.usa_fdd_lamp(2) != 0,
            cz.usa_fdd_lamp(3) != 0,
        },
    });

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bindings);
    sg.draw(0, 6, 1);
    sdtx.draw();
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    cz.pccore_term();
    ui.shutdown();
    saudio.shutdown();
    sg.shutdown();
}

pub fn main(proc: std.process.Init.Minimal) void {
    const allocator = std.heap.page_allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const argv = proc.args.toSlice(arena.allocator()) catch {
        std.debug.print("!! could not read argv\n", .{});
        return;
    };
    // Skip argv[0] (program name).
    const args_slice: []const [:0]const u8 = if (argv.len > 0) argv[1..] else argv[0..0];
    const args_const: []const []const u8 = @ptrCast(args_slice);

    var opts = cli.parse(allocator, args_const) catch |err| {
        std.debug.print("!! CLI parse error: {s}\n\n{s}", .{ @errorName(err), cli.usage_text });
        return;
    };
    if (opts.help) {
        std.debug.print("{s}", .{cli.usage_text});
        opts.deinit(allocator);
        return;
    }
    parsed_opts = opts;
    defer if (parsed_opts) |*p| p.deinit(allocator);

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = input.handleEvent,
        .width = WIN_WIDTH,
        .height = WIN_HEIGHT,
        .window_title = "UsaProject",
        .high_dpi = false,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
