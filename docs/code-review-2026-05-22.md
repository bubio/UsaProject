# Code Review — 2026-05-22 (Phase 2 末)

対象: `src/main.zig`, `src/np2_glue.c`, `src/c.zig`, `src/root.zig`, `build.zig`。
NP2kai コア本体 (`core/np2kai/`) は対象外。

## サマリ

「動いた」状態としては妥当だが、現時点では「シングルパスで通したスケッチ」に近い。
CLI でディスクイメージを受け取って実機を起動する Phase 3 に進む前に、テスト追加
とリファクタを入れて回帰耐性を上げるべき。

テストは事実上ゼロ (`src/root.zig` に Zig テンプレ由来の `test "basic add"` が1個のみ)。

## 🔴 バグ候補

### 1. `frame()` で `pccore_exec(true)` を毎フレーム1回しか呼ばない (`main.zig:185`)

NP2kai の `pccore_exec` は「1 V-sync 分」を進めるのではなく、CPU 命令の一定サイズしか
進めない可能性がある。sokol の 60fps と PC-98 のクロックが同期していないため、長時間
動かすとエミュ内時間がズレる可能性。Phase 3 で時刻ベースのループに置き換え必要。

### 2. データディレクトリが無くても無言で失敗 (`main.zig:216`)

`resolveDataDir` でパスを返すだけで `mkdir -p` も access チェックも無い。初回起動時に
は `file_open_rb failed` が大量に出るだけ。`std.fs.makeDirAbsolute` 等で先に作るのが親切。

### 3. `file_seek` の `method` 引数を素通し (`np2_glue.c:126`)

NP2kai の `SEEKSET/SEEKCUR/SEEKEND` の定数値が libc の `SEEK_SET=0/CUR=1/END=2` と
一致するかは未確認。ズレるとファイル位置がサイレントに壊れる。`dosio.h` を確認し、
不一致ならスイッチ変換を入れる。

### 4. `file_getext` のセマンティクスが SDL 版と違う (`np2_glue.c:188`)

SDL 版は拡張子が無いとき「文字列末尾 `'\0'` のアドレス」を返すが、こちらは `NULL`。
呼び出し側で NULL 想定がなければクラッシュ。SDL 版に合わせるべき。

### 5. `file_create` だけ診断 printf 無し (`np2_glue.c:125`)

`file_open`/`file_open_rb` には成功/失敗ログがあるが `file_create` だけ無い。
将来 HDD 作成等で問題が起きた時にデバッグしづらい。

## 🟡 設計・可読性

6. **`test_data` という変数名** が誤解を招く (実体はフレームバッファ変換用)。
7. **`state` を匿名構造体リテラル** で定義 — テストから参照しづらい。
8. **`cz.pccore_init_config` と `c.pccore_init` の使い分けが恣意的** — 統一すべき。
9. **`page_allocator` を 70 バイト程度の path 文字列に使用** はオーバーキル。
10. **ウィンドウタイトル "Simple Sampling Test"** はデバッグの残骸。
11. **GLSL/Metal シェーダソースが main.zig 直書き** — `shaders/` に切り出して `@embedFile` か sokol-shdc が後々良い。
12. **`cleanup()` が `pccore_term()` を呼んでいない** — BIOS 書き戻し等に影響し得る。

## 🟢 軽微・将来課題

13. `pc98_framebuffer[640*480]` だが frame() は 400 ラインしか読まない (480 ライン
    モード未対応)。
14. `np2_glue.c` 300 行が1ファイルに集中。`scrn/snd/dosio/...` に分割推奨。
15. `file_open*` の printf が成功時にも流れる。`DEBUG_DOSIO` で gate。
16. `np2cfg.model = "VX"` ハードコード。後で CLI 引数化。

## テストで書きたいもの (優先度順)

1. `np2_set_datadir` の挙動: 末尾 `/` あり/なし、空文字、長すぎる入力
2. `file_catname` の連結セマンティクス: SDL 実装と一致
3. RGB565 → RGBA8 変換: 既知パレット色を `expectEqual`
4. `resolveDataDir`: HOME=`/tmp/foo` で `/tmp/foo/Library/Application Support/UsaProject`

## 全体評価

最低限の整備リスト (Phase 3 着手前):

- [ ] `frame()` の時刻ベースループ
- [ ] `np2_glue.c` の分割
- [ ] デバッグ printf のガード
- [ ] `np2_set_datadir` / `file_catname` のテスト
- [ ] RGB565 変換のテスト
- [ ] `resolveDataDir` のテスト
