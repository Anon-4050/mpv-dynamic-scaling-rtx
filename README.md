# MPV Dynamic Scaling Script using RTX

A Lua script for MPV that dynamically adjusts scaling filters based on RTX Video Super Resolution (VSR) and RTX HDR (Limited implimentation by MPV):
- Window/display size (supports fullscreen/windowed mode)
- Video properties (HDR, pixel format)
- NVIDIA RTX optimizations (`d3d11vpp` filter)

## Features
- Automatically updates scaling when resizing the window or toggling fullscreen.
- Handles 8-bit and HDR content appropriately.
- Uses NVIDIA's `d3d11vpp` for high-quality scaling (requires NVIDIA GPU).

## Installation
1. Run MPV on RTX (through Windows Display settings or Nvidia Control Panel etc)
2. Save the script as `dynamic_scaling.lua` in your MPV scripts folder:
   - **Windows:** `%APPDATA%\mpv\scripts\`
   - **Linux/macOS:** `~/.config/mpv/scripts/`
3. Use provided mpv.config. Add addl parameters if you need specifically (keep observing latency through video-flow)
4. Restart MPV.

## Requirements
- MPV player (with Direct3D11 support - tested on 0.39)
- NVIDIA RTX GPU (for `nvidia-true-hdr` optimization)
- Windows or Linux (tested on these platforms)

## License
MIT License. See [LICENSE](LICENSE) for details.
