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

### Phase 1: Project Setup & sokol Initialization
- [ ] Zigプロジェクトの再初期化 (`zig init`)。
- [ ] `build.zig.zon` に `sokol-zig` への依存関係を追加し、環境を構築。
- [ ] 空のウィンドウを表示するだけの基本的なsokolアプリケーションをZigで実装する。

### Phase 2: Core Build Integration (`build.zig`)
- [ ] NP2kaiコアのうち、エミュレーションに必要最小限のC/C++ソースファイルを特定。
- [ ] `build.zig` にC/C++コンパイルステップを追加し、コアをコンパイル・リンク可能にする。
- [ ] Zigからコアの初期化関数を呼び出せるよう、C APIインターフェースを定義。

### Phase 3: CLI Boot & Main Emulator Loop
- [ ] CLI引数でFDI/HDIなどのディスクイメージパスを受け取る処理を実装。
- [ ] sokolのフレームコールバック (`frame`) 内で、エミュレータの1フレーム分の処理（CPU、デバイスのステップ実行）を呼び出す仕組みを実装。

### Phase 4: Video Output (sokol_gfx)
- [ ] NP2kaiのフレームバッファ（VRAM）から描画結果を取得。
- [ ] sokol_gfxの動的テクスチャ (`sg_update_image`) を用い、画面にレンダリングするパイプラインを構築。

### Phase 5: Input Handling & Shortcuts
- [ ] sokol_app のキーボードイベントをPC-98のキーコードに変換してコアに送信。
- [ ] リセットやディスクイジェクトなどの基本操作をショートカットキーに割り当てる。

### Phase 6: Audio Output (sokol_audio)
- [ ] `sokol_audio` を初期化し、ストリームコールバックを設定。
- [ ] NP2kaiから生成されたPCMデータを取得し、sokol_audioのバッファに供給する。

### Phase 7: Native Dialogs & Integration
- [ ] 実行中のディスク入れ替え等のため、OSネイティブなファイルダイアログ（NFD等）を呼び出せるようにする。

## 4. Verification
各フェーズの完了時に、コンパイルが通ること、および想定するサブシステムが機能しているかを手動およびテストコードで検証する。

## 5. Exit Criteria
コマンドラインからディスクイメージを指定して起動し、sokolのウィンドウ内でゲームの映像が描画され、キー操作および音声出力が正常に行えること。
