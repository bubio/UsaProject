# Nuklear GUI Reference for UsaProject

本プロジェクトで使用している Nuklear (immediate-mode GUI) の実装パターンと注意点。
ソース: `third_party/nuklear/nuklear.h`, sokol_nuklear 経由で利用。

## ビルド構成

- `src/nk.zig` — Zig 側の cImport（ヘッダ解析のみ）
- `src/nuklear_impl.c` — C 実装（`NK_IMPLEMENTATION` + `SOKOL_NUKLEAR_IMPL`）
- **両方に同じ `#define` を揃える必要がある**（片方だけだと ABI 不整合でクラッシュ）

現在有効な define:
```
NK_INCLUDE_FIXED_TYPES
NK_INCLUDE_STANDARD_IO
NK_INCLUDE_DEFAULT_ALLOCATOR
NK_INCLUDE_VERTEX_BUFFER_OUTPUT
NK_INCLUDE_FONT_BAKING
NK_INCLUDE_DEFAULT_FONT
NK_INCLUDE_STANDARD_VARARGS
NK_BUTTON_TRIGGER_ON_RELEASE
```

## ウィンドウとパネルの種類

| 関数 | パネルタイプ | 用途 |
|------|-------------|------|
| `nk_begin` | `NK_PANEL_WINDOW` | トップレベルウィンドウ |
| `nk_popup_begin` | `NK_PANEL_POPUP` | モーダルポップアップ |
| `nk_nonblock_begin` | `NK_PANEL_MENU` 等 | メニュー・コンボ・コンテキストメニュー |

### 入力の隔離

- **ポップアップ/メニュー**: 開くと親パネルに `NK_WINDOW_ROM` を自動設定 → 親のウィジェットは入力無効
- **トップレベルウィンドウ (`nk_begin`)**: 入力隔離なし。同フレーム内の入力が複数ウィンドウに伝播する

## ウィンドウフラグ

### 公開フラグ（`nk_begin` に渡せる）

| フラグ | 説明 |
|--------|------|
| `NK_WINDOW_BORDER` | 枠線 |
| `NK_WINDOW_TITLE` | タイトルバー |
| `NK_WINDOW_MOVABLE` | ドラッグ移動可 |
| `NK_WINDOW_CLOSABLE` | 閉じるボタン（`NK_WINDOW_HIDDEN` を設定） |
| `NK_WINDOW_NO_SCROLLBAR` | スクロールバー非表示 |
| `NK_WINDOW_NO_INPUT` | ウィンドウレベルの入力無効（フォーカス・移動・リサイズ） |

### 内部フラグ（直接渡さない）

| フラグ | 説明 |
|--------|------|
| `NK_WINDOW_ROM` | ウィジェットを読み取り専用に。入力ポインタが NULL になる |
| `NK_WINDOW_HIDDEN` | `NK_WINDOW_CLOSABLE` の X ボタンで設定される |
| `NK_WINDOW_REMOVE_ROM` | `nk_end` 時に ROM を解除 |
| `NK_WINDOW_NOT_INTERACTIVE` | `NK_WINDOW_ROM \| NK_WINDOW_NO_INPUT` |

### NK_WINDOW_ROM の注意

- `nk_begin` のフラグに含めると **永続化**する（`nk_end` で `window->flags = layout->flags` のため）
- 一時的に ROM にしたい場合は `NK_WINDOW_REMOVE_ROM` も同時に設定するか、次フレームで手動解除が必要
- ポップアップ系は自動管理される

## NK_WINDOW_CLOSABLE によるダイアログライフサイクル

X ボタンクリック → `NK_WINDOW_HIDDEN` が設定される。ウィンドウは Nuklear の内部ハッシュテーブルに残る。

**再表示パターン:**
```zig
// 再表示時に nk_begin の前で呼ぶ
c.nk_window_show(ctx, name, c.NK_SHOWN);    // HIDDEN 解除
c.nk_window_set_bounds(ctx, name, bounds);   // 位置リセット（初回のみ）
```

**閉じたか確認:**
```zig
if (c.nk_window_is_hidden(ctx, name) != 0) {
    // 閉じられた
}
```

## メニューバー

```zig
c.nk_menubar_begin(ctx);
// メニュー項目...
c.nk_menubar_end(ctx);
```

### メニュー

```zig
if (c.nk_menu_begin_label(ctx, "Screen", NK_TEXT_LEFT, c.nk_vec2(w, h)) != 0) {
    c.nk_layout_row_dynamic(ctx, 22, 1);
    if (c.nk_menu_item_label(ctx, "Option...", NK_TEXT_LEFT) != 0) {
        // メニュー項目がクリックされた
    }
    c.nk_menu_end(ctx);
}
```

- メニューは内部で `nk_nonblock_begin` を使用（`NK_PANEL_MENU`）
- メニュー外クリックで自動的に閉じる
- **メニューのポップアップはスクロールしない** → 内容がウィンドウ高さを超えると見切れる

## ボタン・チェックボックスのクリック検出

### NK_BUTTON_TRIGGER_ON_RELEASE

```c
#define NK_BUTTON_TRIGGER_ON_RELEASE
```

- 未定義（デフォルト）: マウス**プレス**でトリガー
- 定義済み: マウス**リリース**でトリガー。加えて `down_pos` もウィジェット内であることを要求

### クリック伝播の防止

メニュー項目クリック → ダイアログ表示の際、同じ画面位置にウィジェットがあるとクリックが伝播する。

**対策: メニュー項目処理後にマウス状態をクリア**
```zig
fn clearMouseClick(ctx: *c.nk_context) void {
    ctx.input.mouse.buttons[c.NK_BUTTON_LEFT].clicked = 0;
    ctx.input.mouse.buttons[c.NK_BUTTON_LEFT].down = 0;
}

// メニュー項目でダイアログを開く際
if (c.nk_menu_item_label(ctx, "Option...", c.NK_TEXT_LEFT) != 0) {
    openDialog();
    clearMouseClick(ctx);
}
```

## チェックボックス

```zig
var active: c_int = if (value != 0) 1 else 0;
_ = c.nk_checkbox_label(ctx, "Label", &active);
value = @intCast(active);
```

- `active=1`: カーソル（内側の四角）を描画 → **チェック済み**
- `active=0`: 枠のみ → **未チェック**

### デフォルトテーマの視認性問題

デフォルトダークテーマではカーソル色 (45,45,45) が背景色 (100,100,100) より暗く、チェック状態が「穴」に見える。

**修正: カーソル色を明るくする**
```zig
ctx.style.checkbox.cursor_normal = c.nk_style_item_color(c.nk_rgb(220, 220, 220));
ctx.style.checkbox.cursor_hover = c.nk_style_item_color(c.nk_rgb(255, 255, 255));
```

## ラジオボタン

```zig
if (c.nk_option_label(ctx, "Option A", if (val == 0) @as(c_int, 1) else @as(c_int, 0)) != 0)
    val = 0;
if (c.nk_option_label(ctx, "Option B", if (val == 1) @as(c_int, 1) else @as(c_int, 0)) != 0)
    val = 1;
```

- 戻り値は**現在の active 状態**（クリックされたかどうかではない）
- 選択中のラジオボタンは常に 1 を返すので、対応する値を毎フレーム書き込んでも問題ない

## コンボボックス

```zig
const labels = [_][*:0]const u8{ "A", "B", "C" };
const new_idx: usize = @intCast(c.nk_combo(ctx, &labels, labels.len, @intCast(cur_idx), 22, c.nk_vec2(200, 150)));
```

- 最後の `nk_vec2` はドロップダウンのサイズ
- 内部で `nk_nonblock_begin` を使用

## スライダー

```zig
var f: f32 = @floatFromInt(int_value);
f = c.nk_slide_float(ctx, min, f, max, step);
int_value = @intFromFloat(f);
```

## レイアウト

```zig
// 動的（均等分割）
c.nk_layout_row_dynamic(ctx, height, columns);

// 静的（手動幅指定）
c.nk_layout_row_begin(ctx, c.NK_STATIC, height, columns);
c.nk_layout_row_push(ctx, width);
// ウィジェット...
c.nk_layout_row_end(ctx);

// スペーサー
c.nk_layout_row_dynamic(ctx, 6, 1);
c.nk_spacing(ctx, 1);
```

## 便利な関数

| 関数 | 説明 |
|------|------|
| `nk_window_is_any_hovered(ctx)` | いずれかのウィンドウがホバーされているか |
| `nk_item_is_any_active(ctx)` | UI がアクティブか（3D カメラ等の入力分離に使用） |
| `nk_window_has_focus(ctx)` | 現在のウィンドウにフォーカスがあるか |
| `nk_window_set_focus(ctx, name)` | 指定ウィンドウにフォーカス設定 |
| `nk_window_set_bounds(ctx, name, rect)` | ウィンドウ位置/サイズ変更 |
| `nk_window_show(ctx, name, NK_SHOWN/NK_HIDDEN)` | 表示/非表示切替 |
