# Code Review — 2026-05-22 (Phase 2 末)

対象: `src/main.zig`, `src/np2_glue.c`, `src/c.zig`, `src/root.zig`, `build.zig`。
NP2kai コア本体 (`core/np2kai/`) は対象外。

> **追記 (2026-05-22 同日)**: 本レビューの指摘事項は、Phase 3 着手前の整備として
> ほぼ全件対応済み。各項目末尾に **対応状況** を記載。詳細は当日のコミット
> `Refactor for testability, add unit tests, address review findings` を参照。

## サマリ

「動いた」状態としては妥当だが、当初は「シングルパスで通したスケッチ」に近かった。
CLI でディスクイメージを受け取って実機を起動する Phase 3 に進む前に、テスト追加
とリファクタを入れて回帰耐性を上げるべき、というのが本レビューの主旨。

テストは当初事実上ゼロ (`src/root.zig` に Zig テンプレ由来の `test "basic add"` が
1個のみ) → 現在 **25 テスト全通過** (`zig build test`)。

## 🔴 バグ候補

### 1. `frame()` で `pccore_exec(true)` を毎フレーム1回しか呼ばない (`main.zig:185`)

NP2kai の `pccore_exec` は「1 V-sync 分」を進めるのではなく、CPU 命令の一定サイズしか
進めない可能性がある。sokol の 60fps と PC-98 のクロックが同期していないため、長時間
動かすとエミュ内時間がズレる可能性。Phase 3 で時刻ベースのループに置き換え必要。

**対応**: ✅ 2026-05-23 — 壁時計ベースのスケジューラ `src/frame_scheduler.zig` を導入。
`std.c.clock_gettime(CLOCK.MONOTONIC)` で経過時間を測り、PC-98 1/59.94Hz 分が
経つごとに `pccore_exec(false)` をキャッチアップ呼び出し、最後の 1 回だけ
`pccore_exec(true)` で描画。120Hz/90Hz 等の高リフレッシュ環境でも倍速化しない。
スタール時は最大 4 frame でキャップ (death spiral 防止)。
スケジューラ判定は pure 関数化し 6 件のユニットテストでカバー。

### 2. データディレクトリが無くても無言で失敗 (`main.zig:216`)

`resolveDataDir` でパスを返すだけで `mkdir -p` も access チェックも無い。初回起動時に
は `file_open_rb failed` が大量に出るだけ。

**対応**: ✅ `src/datadir.zig::ensureExists()` で `mkdir(2)` を呼ぶ。
`EEXIST` のみ許容しその他はエラー。

### 3. `file_seek` の `method` 引数を素通し (`np2_glue.c:126`)

**対応**: ✅ 誤検知。`src/dosio.h` / `core/np2kai/sdl/dosio.h` を確認したところ、
`FSEEK_SET=SEEK_SET` 等で libc 定数の単純エイリアスとなっており、ズレは発生しない。

### 4. `file_getext` のセマンティクスが SDL 版と違う (`np2_glue.c:188`)

SDL 版は拡張子が無いとき「文字列末尾 `'\0'` のアドレス」を返すが、当初実装は `NULL`。

**対応**: ✅ `src/np2_path.c::file_getext()` を SDL 版準拠に変更
(`q == NULL` 時に `q = p` で末尾を返す)。`path_test.zig` でテスト追加。

### 5. `file_create` だけ診断 printf 無し (`np2_glue.c:125`)

**対応**: ✅ 失敗時に `printf("file_create failed: %s (errno: %d)\n", ...)` を追加。

### (追加で発見) `_c` 系関数が curpath を経由していない

`file_open_c` / `file_open_rb_c` / `file_create_c` / `file_delete_c` / `file_attr_c` が
単に `file_open(path)` を呼ぶ実装になっていた。SDL バックエンドは内部で `file_getcd`
を呼んで curpath にプレフィクスする想定。NP2kai `bios.c` は
`file_open_c("itf.rom")` のように相対名で呼ぶため、データディレクトリから引けない。

**対応**: ✅ 全ての `_c` 系を `file_open(file_getcd(path))` 形式に修正。

## 🟡 設計・可読性

### 6. `test_data` という変数名 が誤解を招く

**対応**: ✅ `fb_rgba` に改名。

### 7. `state` を匿名構造体リテラル で定義

**対応**: ✅ `const State = struct { ... }; var state: State = .{};` に変更。

### 8. `cz.pccore_init_config` と `c.pccore_init` の使い分けが恣意的

**対応**: ✅ `src/c.zig` で NP2kai entry points (`pccore_init/term/reset/exec`,
`scrndraw_redraw`) を `cz.*` に re-export し統一。

### 9. `page_allocator` を 70 バイト程度の path 文字列に使用 はオーバーキル

**対応**: ✅ `FixedBufferAllocator` (4096 バイトスタックバッファ) に変更。

### 10. ウィンドウタイトル "Simple Sampling Test" はデバッグの残骸

**対応**: ✅ `"UsaProject"` に変更。

### 11. GLSL/Metal シェーダソースが main.zig 直書き

**対応**: ✅ 2026-05-23 — `src/shaders/` に `blit.{vs,fs}.{glsl,metal}` を分離し
`@embedFile` でロード。`makeBlitShader()` 内では platform 分岐するだけになった。

### 12. `cleanup()` が `pccore_term()` を呼んでいない

**対応**: ✅ `cleanup()` 内で `cz.pccore_term()` を呼ぶように変更。

## 🟢 軽微・将来課題

### 13. `pc98_framebuffer[640*480]` だが frame() は 400 ラインしか読まない (480 ラインモード未対応)

**対応**: ⏳ 将来課題。31kHz モード対応時に解像度切替を実装。

### 14. `np2_glue.c` 300 行が1ファイルに集中

**対応**: 🟡 部分的 — パス関連を `src/np2_path.c` / `np2_path.h` に分離。
残りの scrn/snd/sysmng 等は当面のサイズなら同居で問題なし。

### 15. `file_open*` の printf が成功時にも流れる

**対応**: ✅ `#ifdef DEBUG_DOSIO` でゲート。ビルドフラグに追加しない限り失敗のみログ。

### 16. `np2cfg.model = "VX"` ハードコード

**対応**: ✅ 2026-05-23 — `src/cli.zig` の `--model` オプションで VM/VX/286/EPSON
を切替可能 (デフォルト VX)。`np2_set_model()` glue で `pccore_init` 前に上書き。

## テストで書きたいもの (優先度順)

| # | 内容 | ファイル | 件数 | 状態 |
|---|---|---|---|---|
| 1 | `np2_set_datadir` の挙動 | `src/path_test.zig` | 3 | ✅ |
| 2 | `file_catname` 連結セマンティクス | `src/path_test.zig` | 2 | ✅ |
| 3 | RGB565 → RGBA8 変換 | `src/pixel.zig` | 7 | ✅ |
| 4 | `resolveDataDir` | `src/datadir.zig` | 4 | ✅ |
| — | `file_cutname` / `file_getname` / `file_getext` / `file_setcd` | `src/path_test.zig` | 8 | ✅ (追加分) |

合計 24 + 既存テンプレ 1 = **25 テスト全通過**。`zig build test` で実行可能。

## 残課題 (2026-05-23 時点)

- 🟢 13: 480 ライン (31kHz) モード対応 — 解像度切替と sokol_app のウィンドウ
  リサイズ対応を含むため別タスク (Phase 5/6 あたりで検討)

> 当初の Phase 3 残課題 4 件のうち、#1 (時刻ベースループ)、#11 (シェーダ
> embed)、#16 (model 化) は 2026-05-23 のセッションで全て対応済み。

## 全体評価 (修正後)

当初の指摘事項は対応可能なものをすべて潰し、リファクタによってテスト可能な
構造に整理した。Phase 3 (CLI でディスクイメージを受け取って起動) に着手する
準備が整った状態。
