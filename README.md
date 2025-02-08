# MPV Dynamic Scaling Script

A Lua script for MPV that dynamically adjusts scaling filters based on:
- Window/display size (supports fullscreen/windowed mode)
- Video properties (HDR, pixel format)
- NVIDIA GPU optimizations (`d3d11vpp` filter)

## Features
- Automatically updates scaling when resizing the window or toggling fullscreen.
- Handles 8-bit and HDR content appropriately.
- Uses NVIDIA's `d3d11vpp` for high-quality scaling (requires NVIDIA GPU).

## Installation
1. Save the script as `dynamic_scaling.lua` in your MPV scripts folder:
   - **Windows:** `%APPDATA%\mpv\scripts\`
   - **Linux/macOS:** `~/.config/mpv/scripts/`
2. Restart MPV.

## Requirements
- MPV player (with Direct3D11 support)
- NVIDIA GPU (for `nvidia-true-hdr` optimization)
- Windows or Linux (tested on these platforms)

## License
MIT License. See [LICENSE](LICENSE) for details.
