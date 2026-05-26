# PC-98 Emulator Project (UsaProject)

## Overview
PC-98エミュレーターの開発プロジェクト。NP2kaiのコアをベースに、モダンな言語とライブラリでアプリケーション層を再構築します。

## Core Technical Stack
- **Core Engine:** [NP2kai (wx_alpha branch)](https://github.com/AZO234/NP2kai/tree/wx_alpha)
- **Application Layer:** Zig
- **Graphics/Audio/Platform:** sokol (sokol_gfx, sokol_app, sokol_audio)
- **Target Platforms:** macOS, Linux, Windows

## Project Goals & Scope
- **Primary Goal:** 大半のPC-98ゲームが動作すること。
- **Non-Goals:**
    - NP2kaiの全機能の完全な再現。
    - 特殊な周辺機器のエミュレーション。
- **Design Philosophy:** 
    - 移植性とメンテナンス性を重視。
    - アプリケーション層はZigで記述し、コア（C/C++）との連携を最適化する。
    - **UI Strategy:** 
        - 初期フェーズはCLIベース（引数でのディスク指定やショートカットキー操作）で構築。
        - その後、OSネイティブダイアログの活用 (e.g., nfd-zig等によるファイルブラウザ) を組み合わせる。
        - エミュレータ画面上の簡易UIについては、必要に応じて軽量なライブラリ（Nuklearや自前描画）を検討する。

## Development Conventions
- コア部分は必要に応じてNP2kaiから抽出・調整する。
- ウィンドウ管理、描画、音声出力は sokol を利用する。
- Zigのビルドシステム（build.zig）を活用して依存関係を管理し、NP2kaiコアも統合してビルドする。
- **Nuklear GUI の実装パターンは [docs/nuklear-reference.md](docs/nuklear-reference.md) を参照。** メニュー→ダイアログのクリック伝播防止、ウィンドウフラグ、チェックボックス視認性修正など。
- **OS依存コードは `src/platform/` 配下にまとめる。** OS固有のAPI呼び出し（Win32, POSIX, Cocoa 等）や、`std.os.windows` / `std.posix` / `std.c` を直接触る処理は、`src/platform/{windows,linux,macos}.zig` にそれぞれ実装し、共通インターフェイスとして `src/platform.zig` の `platform.os.*` 経由で呼び出すこと。`src/main.zig` などのアプリ層に `#ifdef` 的な OS 分岐を持ち込まない。
