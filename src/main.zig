const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;
const cz = @import("c.zig");
const c = cz.c;
const pixel = @import("pixel.zig");
const datadir = @import("datadir.zig");

const FB_WIDTH = 640;
const FB_HEIGHT = 400;

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

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    setupDataDir();

    cz.pccore_init_config();
    cz.pccore_init();
    cz.pccore_reset();

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
            .source = if (!is_macos)
                \\#version 450
                \\layout(location=0) in vec4 position;
                \\layout(location=1) in vec2 texcoord0;
                \\out vec2 uv;
                \\void main() {
                \\  gl_Position = position;
                \\  uv = texcoord0;
                \\}
            else
                \\#include <metal_stdlib>
                \\using namespace metal;
                \\struct vs_in {
                \\  float4 position [[attribute(0)]];
                \\  float2 texcoord0 [[attribute(1)]];
                \\};
                \\struct vs_out {
                \\  float4 position [[position]];
                \\  float2 uv;
                \\};
                \\vertex vs_out _main(vs_in in [[stage_in]]) {
                \\  vs_out out;
                \\  out.position = in.position;
                \\  out.uv = in.texcoord0;
                \\  return out;
                \\}
        },
        .fragment_func = .{
            .entry = if (!is_macos) "main" else "_main",
            .source = if (!is_macos)
                \\#version 450
                \\precision mediump float;
                \\layout(binding=0) uniform texture2D tex;
                \\layout(binding=0) uniform sampler smp;
                \\in vec2 uv;
                \\out vec4 frag_color;
                \\void main() {
                \\  frag_color = texture(sampler2D(tex, smp), uv);
                \\}
            else
                \\#include <metal_stdlib>
                \\using namespace metal;
                \\struct fs_in {
                \\  float2 uv;
                \\};
                \\fragment float4 _main(fs_in in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
                \\  return tex.sample(smp, in.uv);
                \\}
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
    cz.pccore_exec(true);
    cz.scrndraw_redraw();

    pixel.rgb565BufferToRgba8(&fb_rgba, cz.pc98_framebuffer[0 .. FB_WIDTH * FB_HEIGHT]);

    var img_data = sg.ImageData{};
    img_data.mip_levels[0] = sg.asRange(&fb_rgba);
    sg.updateImage(state.image, img_data);

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bindings);
    sg.draw(0, 6, 1);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    cz.pccore_term();
    sg.shutdown();
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = FB_WIDTH,
        .height = FB_HEIGHT,
        .window_title = "UsaProject",
        .high_dpi = false,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
