const sokol = @import("sokol");
const sapp = sokol.app;

// 日本語 GUI フォント本体 (M PLUS 1p Regular)。build.zig の addAnonymousImport で
// 埋め込んだ TTF バイト列。アプリ全体で生存する静的データ。
const ja_font = @embedFile("ja_font");

pub const c = @cImport({
    @cInclude("sokol_gfx.h");
    @cInclude("sokol_app.h");
    @cDefine("NK_INCLUDE_FIXED_TYPES", "");
    @cDefine("NK_INCLUDE_STANDARD_IO", "");
    @cDefine("NK_INCLUDE_DEFAULT_ALLOCATOR", "");
    @cDefine("NK_INCLUDE_VERTEX_BUFFER_OUTPUT", "");
    @cDefine("NK_INCLUDE_FONT_BAKING", "");
    @cDefine("NK_INCLUDE_DEFAULT_FONT", "");
    @cDefine("NK_INCLUDE_STANDARD_VARARGS", "");
    @cDefine("NK_BUTTON_TRIGGER_ON_RELEASE", "");
    @cInclude("nuklear.h");
    @cInclude("sokol_nuklear.h");
});

pub fn setup(desc: c.snk_desc_t) void {
    c.snk_setup(&desc);
}

// sokol 内部のフォントアトラス (_snuklear.atlas) を返すアクセサ。実体は
// src/nuklear_impl.c。snk_shutdown() がこのアトラスを nk_font_atlas_clear で
// 後始末するため、独自アトラスではなくこれへ焼き込む。
extern fn snk_internal_atlas() *c.nk_font_atlas;

// snk_setup(.{ .no_default_font = true }) の後に一度だけ呼ぶ。M PLUS 1p を
// 焼き込んでフォントアトラスを差し替え、Nuklear のスタイルフォントに設定する。
// 手順は sokol_nuklear.h の既定フォント生成 (no_default_font == false の経路) を踏襲し、
// 既定経路と同じ _snuklear.atlas へ焼き込むことで終了時の後始末も sokol に委ねる。
pub fn setupFont(px: f32) void {
    const font_atlas = snk_internal_atlas();
    c.nk_font_atlas_init_default(font_atlas);
    c.nk_font_atlas_begin(font_atlas);

    var cfg = c.nk_font_config(px);
    // ASCII + CJK 記号 + ひらがな/カタカナ (0x3000-0x30FF) + CJK 統合漢字を含むため
    // 日本語表示に十分。
    cfg.range = c.nk_font_chinese_glyph_ranges();
    cfg.oversample_h = 1;
    cfg.oversample_v = 1;

    const font = c.nk_font_atlas_add_from_memory(
        font_atlas,
        @constCast(@ptrCast(ja_font)),
        ja_font.len,
        px,
        &cfg,
    );

    var img_w: c_int = 0;
    var img_h: c_int = 0;
    const pixels = c.nk_font_atlas_bake(font_atlas, &img_w, &img_h, c.NK_FONT_ATLAS_RGBA32);

    var img_desc = c.sg_image_desc{};
    img_desc.width = img_w;
    img_desc.height = img_h;
    img_desc.pixel_format = c.SG_PIXELFORMAT_RGBA8;
    img_desc.data.mip_levels[0] = .{
        .ptr = pixels,
        .size = @intCast(img_w * img_h * 4),
    };
    img_desc.label = "ja-font-image";
    const img = c.sg_make_image(&img_desc);

    var view_desc = c.sg_view_desc{};
    view_desc.texture.image = img;
    view_desc.label = "ja-font-texview";
    const tex_view = c.sg_make_view(&view_desc);

    var smp_desc = c.sg_sampler_desc{};
    smp_desc.min_filter = c.SG_FILTER_LINEAR;
    smp_desc.mag_filter = c.SG_FILTER_LINEAR;
    smp_desc.wrap_u = c.SG_WRAP_CLAMP_TO_EDGE;
    smp_desc.wrap_v = c.SG_WRAP_CLAMP_TO_EDGE;
    smp_desc.label = "ja-font-sampler";
    const smp = c.sg_make_sampler(&smp_desc);

    var snk_img_desc = c.snk_image_desc_t{};
    snk_img_desc.texture_view = tex_view;
    snk_img_desc.sampler = smp;
    const snk_img = c.snk_make_image(&snk_img_desc);

    c.nk_font_atlas_end(font_atlas, c.snk_nkhandle(snk_img), null);
    c.nk_font_atlas_cleanup(font_atlas);

    // snk 内部の nk_context ポインタを取得するために new_frame を一度呼ぶ
    // (描画前なので副作用なし)。スタイルフォントとカーソルを設定する。
    const ctx = c.snk_new_frame();
    if (font) |f| {
        c.nk_style_set_font(ctx, &f.*.handle);
    }
    c.nk_style_load_all_cursors(ctx, &font_atlas.cursors[0]);
}

pub fn newFrame() *c.nk_context {
    return c.snk_new_frame();
}

pub fn render(width: c_int, height: c_int) void {
    c.snk_render(width, height);
}

pub fn handleEvent(ev: *const sapp.Event) bool {
    return c.snk_handle_event(@ptrCast(ev));
}

pub fn shutdown() void {
    c.snk_shutdown();
}
