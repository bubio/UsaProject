# UsaProject

<p align="center">
  <img src="assets/AppIcon.png" alt="UsaProject" width="128" height="128">
</p>

<p align="center">
  <a href="https://github.com/bubio/UsaProject/releases/latest">
    <img src="https://img.shields.io/github/v/release/bubio/UsaProject" alt="Latest Release">
  </a>
  <a href="https://github.com/bubio/UsaProject/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/bubio/UsaProject" alt="License">
  </a>
  <a href="https://github.com/bubio/UsaProject/releases/latest">
    <img src="https://img.shields.io/github/downloads/bubio/UsaProject/total.svg" alt="Downloads">
  </a>
</p>

A PC-98 emulator frontend rebuilt with **Zig** and **sokol**, powered by the **NP2kai** core. 
This project aims to provide a lightweight, modern, and cross-platform PC-98 experience.

<p align="center">
  <img src="assets/UsaProject.png" alt="UsaProject App ScreenShot">
</p>

## Features

*   **NP2kai Core**: High-compatibility PC-98 emulation.
*   **Modern Graphics**: Rendered using `sokol_gfx` and `sokol_gl` for a fast and clean UI.
*   **Cross-Platform**: Native support for macOS, Linux, and Windows.
*   **Lightweight**: Built with Zig for minimal overhead and easy distribution.

## Supported OS

*   **macOS**: macOS 13 Ventura or later (Apple Silicon & Intel)
*   **Linux**: Modern distributions (Ubuntu 22.04+ recommended)
*   **Windows**: Windows 11 or later

## License

This project incorporates several open-source components:

*   **NP2kai**: MIT License (AZO)
*   **Zig**: MIT License
*   **sokol**: zlib/libpng License
*   **nativefiledialog-extended**: Zlib License

## Build

### Prerequisites

*   [Zig 0.16.0-dev](https://ziglang.org/download/) or later.

### macOS

To create a standalone `.app` bundle with the icon:

```bash
zig build bundle -Doptimize=ReleaseFast
```
The output will be in `zig-out/UsaProject.app`.

### Linux

```bash
# Required packages (Ubuntu / Debian)
sudo apt-get install -y \
  libasound2-dev libdbus-1-dev libx11-dev libxi-dev libxcursor-dev libgl-dev

zig build -Doptimize=ReleaseFast
```

### Windows

```powershell
zig build -Doptimize=ReleaseFast
```
