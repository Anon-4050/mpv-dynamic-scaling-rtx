# legacy

The first version of this repository (February 2025), kept unchanged for reference:

- `mpv-dynamic-scaling.lua`: sets `d3d11vpp` with NVIDIA scaling and `nvidia-true-hdr` from the window and video size.
- `mpv.conf`: the config it shipped with.

**Do not use it together with `scripts/aspect-rtx.lua`.** Both set mpv's `d3d11vpp` filter (`vf set` here replaces
the whole filter chain), so they overwrite each other's chain. `aspect-rtx.lua` (v1.0.0 of this repo) covers everything
this script did and adds the aspect crop, HDR-source and Windows-HDR detection, the display peak tag, fullscreen-only
mode and self-repair of the chain.
