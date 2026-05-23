# PC-98 Emulator Development Plan (UsaProject with sokol)

## 1. Background & Motivation
NP2kaiのコアを利用しつつ、アプリケーション層をZigおよびsokol(クロスプラットフォーム対応ライブラリ)で再構築し、保守性が高くモダンな環境で動作するPC-98エミュレータを開発する。目標は「大半のゲームの動作」であり、完全な周辺機器の再現や全機能のエミュレーションは対象外とする。

## 2. Scope & Architecture
- **Core:** NP2kai (wx_alpha branch)のC/C++ソースコード。
- **App/Platform:** Zig + sokol (sokol_gfx, sokol_app, sokol_audio)。
- **Build System:** `build.zig` でZigコードとNP2kaiのC/C++コードを統合してビルドする。
- **UI/UX Strategy:** 
  1. CLI引数起動（初期フェーズ）
  2. OSネイティブダイアログの活用 (ファイル選択など)
  3. 軽量なメニュー描画 (必要に応じて)
- **Platforms:** macOS, Linux, Windows

## 3. Implementation Phases

### Phase 1: Project Setup & sokol Initialization ✅ (2026-05-22)
- [x] Zigプロジェクトの再初期化 (`zig init`)。
- [x] `build.zig.zon` に `sokol-zig` への依存関係を追加し、環境を構築。
- [x] 空のウィンドウを表示するだけの基本的なsokolアプリケーションをZigで実装する。

### Phase 2: Core Build Integration (`build.zig`) ✅ (2026-05-22)
- [x] NP2kaiコアのうち、エミュレーションに必要最小限のC/C++ソースファイルを特定。
- [x] `build.zig` にC/C++コンパイルステップを追加し、コアをコンパイル・リンク可能にする。
- [x] Zigからコアの初期化関数を呼び出せるよう、C APIインターフェースを定義。

### Phase 3: CLI Boot & Main Emulator Loop ✅ (2026-05-23)
- [x] CLI引数でFDI/HDIなどのディスクイメージパスを受け取る処理を実装。
  - `src/cli.zig` (pure-Zig パーサ + 16 tests)。拡張子で FDD/HDD 自動振り分け、
    `--model VM|VX|286|EPSON` でモデル切替、`-h`/`--help` でヘルプ。
- [x] sokolのフレームコールバック (`frame`) 内で、エミュレータの1フレーム分の
      処理を呼び出す仕組みを実装。
  - `src/frame_scheduler.zig` で壁時計ベースのキャッチアップループを実装
    (PC-98 1/59.94Hz, max 4 frame catch-up, 6 tests)。
- [x] **動作確認**: `Wizardry2.FDI` で実機ブートまで到達 (BIOS 起動 → ディスク
      ブート → ゲームタイトル画面表示)。

### Phase 4: Video Output (sokol_gfx) ✅ (2026-05-22)
- [x] NP2kaiのフレームバッファ（VRAM）から描画結果を取得。
- [x] sokol_gfxの動的テクスチャ (`sg_update_image`) を用い、画面にレンダリング
      するパイプラインを構築。
- [ ] 480 ライン (31kHz) モード対応 — 解像度切替と sokol_app のウィンドウ
      リサイズ対応含む。Phase 5/6 と合わせて検討。

### Phase 5: Input Handling & Shortcuts
- [x] sokol_app のキーボードイベントをPC-98のキーコードに変換してコアに送信。
- [x] リセットやディスクイジェクトなどの基本操作をショートカットキーに割り当てる。

### Phase 6: Audio Output (sokol_audio)
- [x] `sokol_audio` を push モードで初期化。
- [x] NP2kaiから生成されたPCMデータ(SINT32)をf32変換し、sokol_audioへ供給。
- [x] FIFO 空き容量で throttle してドロップアウト/ぶちぶち音を防止。
- [x] `snd86opt` を IRQ12/ポート0x188 に設定し FM 検出を有効化。

### Phase 7: UI Overlay & Native Dialogs
- [x] **Step 1 — レイアウト基盤 (2026-05-23)**: sokol_debugtext (sdtx) を導入。
      ウィンドウを 640×440 に拡張し、上 20px をメニュー領域、下 20px をステータス
      バーとして確保。PC-98 描画用クアッドを NDC で `±(FB_HEIGHT/WIN_HEIGHT)`
      にオフセット。プレースホルダ表示で動作確認済み。
- [ ] **Step 2 — ステータスバー**: FPS / CPU クロック / FDD アクセスランプを
      実データで表示。FPS は `sapp.frameDuration()` から算出済み。残りは NP2kai
      の状態取得 C ブリッジを追加する。
- [ ] **Step 3 — メニューバー**: クリック検出 + ドロップダウン (File / System /
      Help) を sdtx ベースで実装。
- [ ] **Step 4 — NFD 統合**: nativefiledialog-extended を build.zig に組み込み、
      メニュー項目から OS ネイティブダイアログを呼び出して `np2_insert_fdd` /
      `np2_insert_hdd` に渡す。

## 4. Verification
各フェーズの完了時に、コンパイルが通ること、および想定するサブシステムが機能しているかを手動およびテストコードで検証する。

現時点で `zig build test` は **48/48 pass**:
- `src/pixel.zig` (7) — RGB565→RGBA8 変換
- `src/datadir.zig` (4) — OS-conventional パス解決
- `src/cli.zig` (16) — CLI パーサ
- `src/frame_scheduler.zig` (6) — 時刻ベーススケジューラ
- `src/path_test.zig` (13) — NP2kai パス互換層 (C 経由)
- `src/root.zig` 由来テンプレ (2)

## 5. Exit Criteria
コマンドラインからディスクイメージを指定して起動し、sokolのウィンドウ内でゲームの映像が描画され、キー操作および音声出力が正常に行えること。

**現状**: Phase 1〜6 完了。Exit Criteria (映像/入力/音声) を満たす。
残るは Phase 7 (ネイティブダイアログ)。

## 6. 動作確認済みディスクイメージ

| イメージ | 形式 | 結果 |
|---|---|---|
| Wizardry2.FDI | 標準 NP2 FDI (2HD) | ✅ タイトル画面まで起動 |
| YS.FDI | Anex86 "FDI2" v2 | ❌ NP2kai が形式非対応 |

新しいイメージを試すときは `xxd image | head -1` で先頭を確認:
- 先頭 4 バイトが `46 44 49 32` ("FDI2") は Anex86 v2 で使えない
- 先頭が `00 00 00 00 90 00 00 00` のような標準 FDI なら高確率で動く
- `.d88` は鉄板
