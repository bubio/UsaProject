#include "sokol_gfx.h"
#include "sokol_app.h"

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_BUTTON_TRIGGER_ON_RELEASE
#define NK_IMPLEMENTATION
#include "nuklear.h"

#define SOKOL_NUKLEAR_IMPL
#include "sokol_nuklear.h"

// no_default_font = true でカスタムフォントを焼き込む際、sokol 内部の
// フォントアトラス (_snuklear.atlas) へアクセスするためのアクセサ。
// 既定フォント経路 (no_default_font == false) と同じ _snuklear.atlas へ
// 焼き込めば、snk_shutdown() の nk_font_atlas_clear(&_snuklear.atlas) が
// そのまま後始末する。独自アトラスを持つと内部アトラスが未初期化のままとなり、
// 終了時に nk_font_atlas_clear のアサートで abort するため、それを避ける。
// _snuklear はこの翻訳単位 (SOKOL_NUKLEAR_IMPL) の static なのでここから参照可能。
struct nk_font_atlas *snk_internal_atlas(void) {
    return &_snuklear.atlas;
}
