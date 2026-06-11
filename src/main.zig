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
const platform = @import("platform.zig");
const cli = @import("cli.zig");
const archive = @import("archive.zig");
const scheduler = @import("frame_scheduler.zig");
const input = @import("input.zig");
const audio = @import("audio.zig");
const ui = @import("ui.zig");
const nfd = @import("nfd.zig");
const nk = @import("nk.zig");
const config = @import("config.zig");
const history = @import("history.zig");

const app_icon_rgba = @embedFile("AppIcon128.raw");

fn makeAppIcon() sapp.IconDesc {
    // macOS では .app バンドルの AppIcon.icns（余白付き・マルチ解像度）を Dock に使わせる。
    // ランタイムで上書きすると余白なしの埋め込み画像になり、起動中だけ Dock アイコンが
    // 他アプリより大きく見えてしまうため、何も設定しない（空 desc で sokol は上書きしない）。
    if (builtin.os.tag == .macos) {
        return .{ .sokol_default = false };
    }
    var desc: sapp.IconDesc = .{ .sokol_default = false };
    desc.images[0] = .{
        .width = 128,
        .height = 128,
        .pixels = .{ .ptr = app_icon_rgba.ptr, .size = app_icon_rgba.len },
    };
    return desc;
}

const FB_WIDTH = 640;
const FB_HEIGHT = 400;
const WIN_WIDTH = FB_WIDTH;
const WIN_HEIGHT = FB_HEIGHT + ui.MENU_HEIGHT + ui.STATUS_HEIGHT;

const Viewport = struct { x: i32, y: i32, w: i32, h: i32 };

// PC-98 framebuffer placement: reserve MENU/STATUS bars, then fit the largest
// integer multiple of 640x400 inside the remaining area and center it.
fn fbViewport(win_w: u32, win_h: u32) Viewport {
    const reserved = ui.MENU_HEIGHT + ui.STATUS_HEIGHT;
    const avail_w = win_w;
    const avail_h = if (win_h > reserved) win_h - reserved else 0;
    var n: u32 = @min(avail_w / FB_WIDTH, avail_h / FB_HEIGHT);
    if (n < 1) n = 1;
    const fw = FB_WIDTH * n;
    const fh = FB_HEIGHT * n;
    const vx: i32 = @intCast((avail_w -| fw) / 2);
    const vy: i32 = @as(i32, @intCast(ui.MENU_HEIGHT)) + @as(i32, @intCast((avail_h -| fh) / 2));
    return .{ .x = vx, .y = vy, .w = @intCast(fw), .h = @intCast(fh) };
}

const State = struct {
    pipeline: sg.Pipeline = .{},
    // Second pipeline whose fragment shader applies the HSV-smooth filter on the
    // GPU; selected at draw time when ui.display_hsv is on. Keeping the filter in
    // a shader means the NP2kai core needs no video-filter changes.
    pipeline_hsv: sg.Pipeline = .{},
    bindings: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
    image: sg.Image = .{},
    view: sg.View = .{},
    sampler: sg.Sampler = .{},
    sampler_linear: sg.Sampler = .{},
};

var state: State = .{};
var fb_rgba: [FB_WIDTH * FB_HEIGHT]u32 = undefined;
var parsed_opts: ?cli.Options = null;
// Disk list after archive expansion: archives are unpacked into their
// contained FDD/HDD images here. `image_sets` owns the extracted path strings
// referenced by the expanded disks; both are freed in cleanup().
var expanded_disks: []cli.Disk = &.{};
var image_sets: []archive.ImageSet = &.{};
var last_emu_ns: i128 = 0;
var skip_counter: u32 = 0;
const nowait_frames_per_tick: u32 = 16;
var draw_fps: f32 = 0.0;
// Windowed FPS: average presented-frame count over a ~0.5s wall-clock window.
// Replaces an instantaneous 1/Δt readout, which swung wildly (into the hundreds)
// whenever the host frame() rate beat against the ~60Hz draw gate.
var fps_draw_count: u32 = 0;
var fps_window_start_ns: i128 = 0;

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

    nk.setup(.{ .no_default_font = true });
    nk.setupFont(16.0);
    ui.setup();

    setupDataDir();

    cz.pccore_init_config();
    cz.c.pccore_setdefault();
    cz.usa_apply_config_overrides();
    cz.c.np2cfg.EXTMEM = 1; // default extended memory: 1.6MB (overridden by saved config below)
    cz.usa_set_cpu_index(2); // default CPU: i486SX (overridden by saved config below)
    config.load();
    if (parsed_opts) |opts| {
        if (opts.model) |m| cz.np2_set_model(m.ptr);
        // Unpack any archives (.zip) into their contained images. Runs after
        // setupDataDir() because the extraction cache lives under the data dir.
        expandDisks(opts);
        // HDD images must be registered into np2cfg before pccore_reset(),
        // because the reset's diskdrv_hddbind() binds drives from the config.
        configureHdds(expanded_disks);
    }
    // The HSV-smooth filter now lives in the app layer as a GPU fragment-shader
    // pass (state.pipeline_hsv), so the NP2kai core filter stays disabled and
    // the core source is left unmodified. The --video-filter flag only decides
    // whether the shader filter starts on; the Screen menu toggles it live.
    ui.display_hsv = if (parsed_opts) |o| o.video_filter else false;
    cz.pccore_init();
    cz.pccore_reset();
    if (parsed_opts) |opts| {
        insertFdds(expanded_disks);
        registerCliMounts(expanded_disks);
        if (opts.audio_capture) |p| {
            _ = cz.usa_audio_capture_open(p.ptr, if (opts.audio_autotest) 1 else 0);
        }
    }

    state.image = sg.makeImage(.{
        .width = FB_WIDTH,
        .height = FB_HEIGHT,
        .pixel_format = .RGBA8,
        .usage = .{ .stream_update = true },
    });

    state.view = sg.makeView(.{
        .texture = .{ .image = state.image },
    });

    // Two samplers for the PC-98 screen, swapped live from the Screen menu:
    //   sampler        — nearest-neighbour: crisp integer-scaled pixels (default)
    //   sampler_linear — bilinear: smooth (blurred) upscale
    state.sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
    });
    state.sampler_linear = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
    });

    // Full-screen quad; placement within the window is done via sg.applyViewport.
    const vertices = [_]f32{
        -1.0,  1.0, 0.5,   0.0, 0.0,
         1.0,  1.0, 0.5,   1.0, 0.0,
         1.0, -1.0, 0.5,   1.0, 1.0,
        -1.0, -1.0, 0.5,   0.0, 1.0,
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

    const blit_attrs = init: {
        var attrs: [16]sg.VertexAttrState = @splat(.{});
        attrs[0].format = .FLOAT3;
        attrs[1].format = .FLOAT2;
        break :init attrs;
    };
    state.pipeline = sg.makePipeline(.{
        .shader = makeBlitShader(platform.os.shader_fs_source),
        .layout = .{ .attrs = blit_attrs },
        .index_type = .UINT16,
    });
    // HSV-smooth variant: same geometry/layout, filtering fragment shader.
    state.pipeline_hsv = sg.makePipeline(.{
        .shader = makeBlitShader(platform.os.shader_fs_hsv_source),
        .layout = .{ .attrs = blit_attrs },
        .index_type = .UINT16,
    });

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    };

    // Lock the window to integer-scaled sizes chosen from the Screen menu.
    platform.os.lockWindow(FB_WIDTH, FB_HEIGHT, ui.MENU_HEIGHT + ui.STATUS_HEIGHT);
}

// Build `expanded_disks` from the parsed disks, unpacking each archive into the
// FDD/HDD images it contains. `image_sets` retains ownership of the extracted
// path strings. Failed/empty archives are warned about and skipped.
fn expandDisks(opts: cli.Options) void {
    const allocator = std.heap.page_allocator;
    var disks: std.ArrayList(cli.Disk) = .empty;
    var sets: std.ArrayList(archive.ImageSet) = .empty;

    for (opts.disks) |d| {
        if (d.kind == .archive) {
            var set = archive.extractImages(allocator, d.path) catch |err| {
                std.debug.print("!! skipping archive '{s}': {s}\n", .{ d.path, @errorName(err) });
                continue;
            };
            for (set.images) |img| {
                disks.append(allocator, .{ .kind = img.kind, .path = img.path }) catch {
                    set.deinit();
                    break;
                };
            } else {
                sets.append(allocator, set) catch set.deinit();
                continue;
            }
            // append failed mid-loop: stop expanding further to avoid leaks.
            break;
        }
        disks.append(allocator, d) catch break;
    }

    expanded_disks = disks.toOwnedSlice(allocator) catch &.{};
    image_sets = sets.toOwnedSlice(allocator) catch &.{};
}

// HDDs are registered into np2cfg before pccore_reset() so the reset's
// diskdrv_hddbind() opens and boots them.
fn configureHdds(disks: []const cli.Disk) void {
    var hdd_drv: c_uint = 0;
    for (disks) |d| switch (d.kind) {
        .hdd => {
            if (hdd_drv >= cli.max_hdd) {
                std.debug.print("!! ignoring extra HDD image (max {d}): {s}\n", .{ cli.max_hdd, d.path });
                continue;
            }
            std.debug.print(">>> HDD{d}: {s}\n", .{ hdd_drv, d.path });
            cz.np2_insert_hdd(hdd_drv, d.path.ptr);
            hdd_drv += 1;
        },
        .fdd, .archive => {},
    };
}

// FDDs are inserted after pccore_reset() via the diskdrv ready queue.
fn insertFdds(disks: []const cli.Disk) void {
    var fdd_drv: c_uint = 0;
    for (disks) |d| switch (d.kind) {
        .fdd => {
            if (fdd_drv >= cli.max_fdd) {
                std.debug.print("!! ignoring extra FDD image (max {d}): {s}\n", .{ cli.max_fdd, d.path });
                continue;
            }
            std.debug.print(">>> FDD{d}: {s}\n", .{ fdd_drv, d.path });
            cz.np2_insert_fdd(fdd_drv, d.path.ptr);
            fdd_drv += 1;
        },
        .hdd, .archive => {},
    };
}

// Populate the UI's per-drive slots for disks mounted from the command line, so
// the FDD/HDD menus show what is loaded and offer the source's siblings as swap
// targets. The GUI exposes only drives 0 and 1; extras are ignored. Best-effort
// (registerMount silently no-ops on scan failure).
fn registerCliMounts(disks: []const cli.Disk) void {
    var fdd_drv: u32 = 0;
    var hdd_drv: u32 = 0;
    for (disks) |d| switch (d.kind) {
        .fdd => {
            if (fdd_drv < 2) ui.registerMount(.fdd, fdd_drv, d.path);
            fdd_drv += 1;
        },
        .hdd => {
            if (hdd_drv < 2) ui.registerMount(.hdd, hdd_drv, d.path);
            hdd_drv += 1;
        },
        .archive => {},
    };
}

fn setupDataDir() void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const dir = platform.resolveDataDir(fba.allocator()) catch |err| {
        std.debug.print("!! could not resolve data dir: {s}\n", .{@errorName(err)});
        return;
    };
    platform.ensureExists(dir) catch |err| {
        std.debug.print("!! could not create data dir '{s}': {s}\n", .{ dir, @errorName(err) });
        // Fall through — np2_set_datadir is still useful for read-only files.
    };
    std.debug.print(">>> data dir: {s}\n", .{dir});
    cz.np2_set_datadir(dir.ptr);
    config.setDataDir(dir);
}

fn makeBlitShader(fs_source: [*:0]const u8) sg.Shader {
    return sg.makeShader(.{
        .vertex_func = .{
            .source = platform.os.shader_vs_source,
        },
        .fragment_func = .{
            .entry = platform.os.shader_entry,
            .source = fs_source,
        },
        .attrs = init: {
            var a: [16]sg.ShaderVertexAttr = @splat(.{});
            a[0] = .{ .base_type = .FLOAT, .hlsl_sem_name = "POSITION", .hlsl_sem_index = 0 };
            a[1] = .{ .base_type = .FLOAT, .hlsl_sem_name = "TEXCOORD", .hlsl_sem_index = 0 };
            break :init a;
        },
        .views = init: {
            var v: [32]sg.ShaderView = @splat(.{});
            v[0].texture = .{
                .stage = .FRAGMENT,
                .image_type = ._2D,
                .sample_type = .FLOAT,
                .msl_texture_n = 0,
                .hlsl_register_t_n = 0,
            };
            break :init v;
        },
        .samplers = init: {
            var s: [12]sg.ShaderSampler = @splat(.{});
            s[0] = .{
                .stage = .FRAGMENT,
                .sampler_type = .FILTERING,
                .msl_sampler_n = 0,
                .hlsl_register_s_n = 0,
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
    const now: i128 = platform.os.monotonicNs();
    const nowait = cz.usa_get_nowait() != 0;
    const frames: u32 = if (nowait) blk: {
        last_emu_ns = now;
        break :blk nowait_frames_per_tick;
    } else blk: {
        const decision = scheduler.decide(now, last_emu_ns);
        last_emu_ns = decision.new_last_ns;
        break :blk decision.frames;
    };

    // Run a queued state save/load at a frame boundary, before stepping the CPU,
    // so the heavy file I/O doesn't happen mid-frame from a menu click.
    ui.flushPendingState();

    if (frames > 0) {
        const draw_skip = cz.usa_get_draw_skip();
        var i: u32 = 0;
        while (i < frames) : (i += 1) {
            // Only the final emulated frame of this host frame is ever uploaded
            // to the GPU (a single updateImage() after the loop), so only it
            // needs the expensive scrndraw_draw() + HSV filter pass. Intermediate
            // frames just advance the CPU with draw=false; rendering them — and
            // especially running the per-pixel HSV-smooth filter on them — is
            // pure waste (16x under No-Wait, up to 4x under catch-up) that
            // collapses the frame rate to single digits when the filter is on.
            const is_last = (i + 1 == frames);
            var should_draw = is_last;
            // draw_skip is the user's frame-skip setting; apply it to the one
            // presented frame per host tick so heavy load can drop whole frames.
            if (is_last and draw_skip > 1) {
                skip_counter += 1;
                if (skip_counter >= draw_skip) {
                    skip_counter = 0;
                } else {
                    should_draw = false;
                }
            }
            cz.pccore_exec(should_draw);
            cz.sound_sync();
            if (should_draw) {
                cz.scrndraw_redraw();
                fps_draw_count += 1;
            }
        }
    }

    // Publish smoothed FPS once per ~0.5s window.
    if (fps_window_start_ns == 0) fps_window_start_ns = now;
    const win_ns = now - fps_window_start_ns;
    if (win_ns >= 500_000_000) {
        const win_s = @as(f64, @floatFromInt(win_ns)) / 1_000_000_000.0;
        draw_fps = @floatCast(@as(f64, @floatFromInt(fps_draw_count)) / win_s);
        fps_draw_count = 0;
        fps_window_start_ns = now;
    }

    pixel.rgb565BufferToRgba8(&fb_rgba, cz.pc98_framebuffer[0 .. FB_WIDTH * FB_HEIGHT]);

    var img_data = sg.ImageData{};
    img_data.mip_levels[0] = sg.asRange(&fb_rgba);
    sg.updateImage(state.image, img_data);

    // Update UI overlay state.
    cz.usa_lamp_tick();
    const fps: f32 = draw_fps;

    ui.enforceWindowConstraints();

    const nk_ctx = nk.newFrame();
    const cur_w: u32 = @intCast(sapp.width());
    const cur_h: u32 = @intCast(sapp.height());
    ui.draw(nk_ctx, cur_w, cur_h, .{
        .fps = fps,
        .cpu_mhz = @floatCast(cz.usa_cpu_clock_mhz()),
        .fdd_access = .{
            cz.usa_fdd_lamp(0) != 0,
            cz.usa_fdd_lamp(1) != 0,
            cz.usa_fdd_lamp(2) != 0,
            cz.usa_fdd_lamp(3) != 0,
        },
        .hdd_access = .{
            cz.usa_hdd_lamp(0) != 0,
            cz.usa_hdd_lamp(1) != 0,
            cz.usa_hdd_lamp(2) != 0,
            cz.usa_hdd_lamp(3) != 0,
        },
        .model = std.mem.sliceTo(&c.np2cfg.model, 0),
    });

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(if (ui.display_hsv) state.pipeline_hsv else state.pipeline);
    // Live scaling-filter choice from the Screen menu (nearest vs linear).
    state.bindings.samplers[0] = if (ui.display_scale_linear) state.sampler_linear else state.sampler;
    sg.applyBindings(state.bindings);
    const vp = fbViewport(cur_w, cur_h);
    sg.applyViewport(vp.x, vp.y, vp.w, vp.h, true);
    sg.draw(0, 6, 1);
    nk.render(sapp.width(), sapp.height());
    sg.endPass();
    sg.commit();

    ui.flushPendingActions();
    ui.flushDroppedFiles();
}

export fn cleanup() void {
    cz.usa_audio_capture_close();
    config.save();
    history.deinit(); // after save reads the entries
    cz.pccore_term();
    const allocator = std.heap.page_allocator;
    for (image_sets) |*s| s.deinit();
    allocator.free(image_sets);
    allocator.free(expanded_disks);
    nfd.deinit();
    ui.shutdown();
    nk.shutdown();
    saudio.shutdown();
    sg.shutdown();
}

pub fn main(proc: std.process.Init.Minimal) void {
    const allocator = std.heap.page_allocator;

    // Capture the process environment so the "Open Data Folder" menu item can
    // spawn the OS file manager later with PATH and the desktop session vars.
    platform.initSpawn(proc.environ);

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
        .window_title = "Usa Project",
        .high_dpi = false,
        .icon = makeAppIcon(),
        .logger = .{ .func = sokol.log.func },
        .enable_dragndrop = true,
        .max_dropped_files = 4,
        .max_dropped_file_path_length = 4096, // long/Japanese paths (Application Support)
    });
}
