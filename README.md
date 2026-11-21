# mpv dynamic scaling for NVIDIA RTX

mpv scripts for Windows that run NVIDIA **RTX Video Super Resolution (VSR)** and **RTX Video HDR** inside mpv, through
its `d3d11vpp` video filter, with a live aspect-ratio crop in front of them, an on-screen toggle panel and
cadence-aware motion smoothing.

Version: **1.0.0** (see [CHANGELOG.md](CHANGELOG.md)). License: MIT.

## What it does

The video filter chain is built and kept up to date automatically:

```
decoder (d3d11va-copy) -> crop (optional) -> d3d11vpp: RTX VSR and/or RTX Video HDR -> mpv renderer (gpu-next)
```

- **RTX VSR** upscales the video to the screen with NVIDIA's AI upscaler. The scale factor follows the display size and
  the (cropped) video size, so a 1080p video on a 4K screen gets 2x, a 720p video gets 3x.
- **RTX Video HDR** turns SDR video into HDR when Windows HDR is on. The output is tagged with your display's real peak
  brightness (read live by mpv), not mpv's untagged guess of 1000 nits.
- **Aspect crop before VSR** crops to a ratio you pick from presets (for example a 1.9:1 film inside a 16:9 frame:
  the bars go; or a deliberate reframe such as IMAX-style 1.9:1 from a 16:9 picture) *before* the upscaler, and VSR's
  scale factor is computed for the cropped picture. So the **whole** enlargement to the screen is done by VSR.
  (There is no automatic bar detection yet; see Roadmap.) If you crop or zoom *after* VSR instead (mpv's `video-zoom`, `panscan`,
  or cropping an already upscaled frame), VSR only scales the full frame to the screen and the extra zoom that makes
  the picture fill the screen is done by mpv's normal scaler, not by VSR.
- The chain is rebuilt only when something that matters changes (fullscreen, video size, source format, Windows HDR
  mode, display peak). If mpv drops one of the filters, the script puts it back (up to 3 tries).

## Scripts

| File | What it does |
|---|---|
| `scripts/aspect-rtx.lua` | Crop + RTX VSR + RTX Video HDR (the core). Picks scale, pixel format and HDR tag, switches `icc-profile-auto` off only while RTX HDR runs. |
| `scripts/rtx-panel.lua` | On-screen buttons, top-right: **Crop / VSR / RTX HDR / Smooth / Info**. Blue = on, outlined = off, grey = not available, with the reason underneath ("windowed", "HDR source", "no upscale", ...). Appears on mouse movement, hides after 2.5 s. |
| `scripts/smooth.lua` | Frame blending (`interpolation=yes`, `tscale=oversample`): mixes the two real frames around each screen refresh. No invented frames, no "soap-opera" motion. |
| `mpv.conf` | The sample config these scripts are tested with. |
| `input.conf` | Notes only; all keys are bound by the scripts. |
| `legacy/` | The first version of this repo (2025). Replaced by `aspect-rtx.lua`; see [legacy/README.md](legacy/README.md). |

The scripts work alone too: `aspect-rtx.lua` is the only one needed for VSR / RTX HDR. `rtx-panel.lua` shows the
state of whichever of the others are loaded.

## Requirements

- **Windows 10 or 11.** `d3d11vpp` and the NVIDIA video extensions are Direct3D 11 only.
- **NVIDIA RTX GPU** (RTX 20 series or newer) and a current driver (531.18 or newer for VSR, 551.23 or newer for RTX Video HDR).
- **NVIDIA app / Control Panel:** *RTX Video Enhancement* -> **Super Resolution** on. For HDR also **RTX Video HDR** on.
  The quality level you pick there is what the driver uses.
- **mpv 0.40 or newer for VSR; tested on 0.42.** RTX Video HDR needs a build whose `d3d11vpp` has the
  `nvidia-true-hdr` option (check with `mpv --vf=d3d11vpp=help`; 0.42 has it). Required settings:
  - `gpu-context=d3d11` (required)
  - `hwdec=d3d11va-copy` (required for the crop; plain `d3d11va` is switched to `-copy` automatically when a crop is active)
  - `vo=gpu-next` (mpv's default; tested)
- **Laptops with two GPUs (Intel/AMD + NVIDIA):** keep `d3d11-adapter=NVIDIA`. Without it Windows can run mpv on the
  integrated GPU, where neither VSR nor RTX HDR exists.
- **RTX Video HDR** also needs Windows HDR on (*Settings -> System -> Display -> Use HDR*).

## Install

1. Find your mpv config folder:
   - portable mpv: `portable_config\` next to `mpv.exe` (create it if missing)
   - installed mpv: `%APPDATA%\mpv\`
2. Copy the `scripts\` folder into it.
3. Merge `mpv.conf` into your own `mpv.conf`: at least `gpu-context`, `d3d11-adapter`, `hwdec`, `video-sync` and the
   `script-opts-append` lines you want. Remove any other script or `vf=` line that sets `d3d11vpp`
   (e.g. `autovsr.lua` or the legacy `mpv-dynamic-scaling.lua`).
4. Start a video, go fullscreen, press `Ctrl+S`: the status shows the active filter chain and the display mode.

Scripts in `scripts\` load automatically; no `script=` line is needed.

## Key bindings

| Key | Action | Script |
|---|---|---|
| `Alt+a` | Cycle crop: original -> each preset -> original | aspect-rtx |
| `Alt+1` / `Alt+0` | Crop off (original frame) | aspect-rtx |
| `Alt+2` | Jump to the preset labelled `16:9` | aspect-rtx |
| `Alt+3` | Jump to the preset labelled `1.9` | aspect-rtx |
| `Ctrl+R` | RTX VSR on / off | aspect-rtx |
| `Ctrl+H` | RTX Video HDR on / off | aspect-rtx |
| `Ctrl+S` | Status: filter chain, decoder, display mode | aspect-rtx |
| `Alt+i` | Smoothing: auto -> on -> off | smooth |
| `Alt+b` | Pin / unpin the on-screen panel | rtx-panel |
| Mouse | Click a panel button to toggle it; right-click *Crop* = crop off | rtx-panel |

Rebind in `input.conf` with `KEY script-binding <script>/<name>`, e.g. `F5 script-binding aspect_rtx/ar-vsr`.
Names: `aspect_rtx/ar-cycle`, `ar-off`, `ar-1`, `ar-2`, `ar-3`, `ar-vsr`, `ar-hdr`, `ar-status`; `smooth/toggle`;
`rtx_panel/toggle`.

## Configuration

All options go in `mpv.conf` as `script-opts-append=<prefix>-<key>=<value>`.

**aspect-rtx** (`aspect_rtx-...`)

| Key | Default | Meaning |
|---|---|---|
| `presets` | `16:9,1.9` | Crop ratios for `Alt+a`, decimal (`1.85`) or W:H (`16:9`). Keep entries labelled `16:9` and `1.9` if you use `Alt+2` / `Alt+3`. The sample config uses `1.9,1.85,1.78,16:9`. |
| `start` | `16:9` | Crop at launch: `original` or a preset label. |
| `vsr` | `yes` | VSR on at start. |
| `hdr` | `yes` | RTX Video HDR on at start. |
| `hdr_peak` | `auto` | HDR peak tag. `auto` (= `display`) follows the display peak mpv reads from Windows and re-tags when it moves by more than 5 nits. Or a fixed number of nits. |
| `peak_store` | `~~cache/aspect-rtx-display-peak.txt` | Last known display peak, so RTX HDR starts at the right value; `""` = do not store. 600 nits is used only if no value was ever read. |
| `hdr_display` | `auto` | `auto` = RTX HDR only when Windows HDR is on; `yes` / `no` to override the detection. |
| `fullscreen_only` | `yes` | VSR / RTX HDR only in fullscreen. The crop works in a window too. |
| `pix_fmt` | `auto` | Force the format into `d3d11vpp`: `nv12`, `p010` or `x2bgr10`. |
| `icc_sdr` | `yes` | Manage `icc-profile-auto`: on, except while RTX HDR runs. `no` leaves your own setting alone. |
| `luma` | `yes` | Add the peak tag (`format=max-luma=N`) after RTX HDR. |

**smooth** `smooth-default` = `auto` (default) | `on` | `off`.
**rtx-panel** `rtx_panel-hide_after` = seconds (default `2.5`), `rtx_panel-pinned` = `yes` | `no`.
## When each feature runs (conditions)

| Feature | Runs when | Stays off when (panel reason) |
|---|---|---|
| RTX VSR | VSR wanted, hardware decode via D3D11 (`d3d11va` / `d3d11va-copy`), fullscreen (with `fullscreen_only=yes`), and the scale to the screen is above 1.0 | software decoding ("software decode"); video already as large as the screen or larger ("no upscale"); windowed ("windowed") |
| RTX Video HDR | HDR wanted, SDR source, hardware decode, fullscreen, Windows HDR on | HDR source (HDR10/HLG/BT.2020 play as they are, "HDR source"); Windows HDR off; windowed; software decoding |
| Crop | a preset is selected and its ratio differs from the video's by more than 0.005; the crop sits before `d3d11vpp`, so VSR scales the cropped picture all the way to the screen | `original` selected, or the video already has that ratio |
| Smoothing (`auto`) | `video-sync=display-resample*` is active and the screen rate is **not** a whole multiple of the video rate (e.g. 25 fps on 60 or 120 Hz, 23.976 on 60 Hz) | even cadence (24/30/60 fps on 120 Hz, 30/60 on 60 Hz: "even cadence"); no display resample ("no resample"); audio-only files ("no video") |
| ICC profile | `icc-profile-auto=yes` whenever RTX HDR is not running | switched off just before RTX HDR starts (an HDR output tone-mapped to an ICC profile's 80-nit white would look dim) |

The scripts do not look at power source: VSR and RTX HDR run the same on battery. See the next section.

## Considerations and limits

- **GPU load and battery.** RTX VSR and RTX HDR run on the GPU's video engine and tensor cores. On a laptop expect
  higher GPU power and fan noise, and much shorter battery life than plain playback. The VSR quality level in the NVIDIA
  app has the largest effect. Press `Ctrl+R` / `Ctrl+H` to switch them off on battery.
- **Which content benefits.** VSR helps most on low and medium resolution sources (480p-1080p) shown on a larger screen,
  and on compressed streams (it also cleans compression artefacts). A 4K video on a 4K screen gets no VSR (scale 1.0).
  RTX HDR helps SDR video on an HDR display; it is an inverse tone map, not the original HDR grade.
- **HDR sources pass through.** HDR10 / HLG video is never sent through RTX HDR; mpv tone-maps it to the display as
  usual. Dolby Vision is handled by mpv, not by this script.
- **Windowed mode.** By default VSR / RTX HDR pause in a window, so resizing a window does not rebuild the GPU chain
  over and over and a small window does not spend GPU power. Set `fullscreen_only=no` to run them windowed too.
- **Copy-back decoding.** `d3d11va-copy` copies frames to system memory and back. It costs a little GPU/bus time but is
  needed for a real crop; with zero-copy `d3d11va` the crop is only metadata and VSR would process the bars too.
- **Other `d3d11vpp` users.** Only one script may set `d3d11vpp`. Remove the legacy script, `vf=d3d11vpp...` lines in
  `mpv.conf` and similar scripts (e.g. other "auto VSR" scripts).
- **Display peak.** The HDR tag follows what Windows reports for the display. If Windows reports a wrong peak (no HDR
  calibration profile, brightness slider, power settings), set `hdr_peak` to a fixed value.
- **Not supported:** Intel / AMD upscalers, Linux and macOS (no `d3d11vpp`). See the roadmap.

## Troubleshooting

| Symptom | Check |
|---|---|
| VSR never turns on | `Ctrl+S`: `hwdec` must be `d3d11va` or `d3d11va-copy`, and `vf` must list `@ar_rtx:d3d11vpp=scaling-mode=nvidia`. Fullscreen? Super Resolution on in the NVIDIA app? |
| `d3d11vpp` listed but no visible upscaling | mpv runs on the wrong GPU: add `d3d11-adapter=NVIDIA`, or set mpv.exe to *High performance* in Windows *Graphics settings*. |
| RTX HDR shows "Windows HDR off" | Turn on Windows HDR, then restart playback. "display not read" = mpv has not reported the output yet; it updates after the first frame. |
| Picture too dark or too bright with RTX HDR | The peak tag follows the display; set `aspect_rtx-hdr_peak=<nits>` to a fixed value, and check the peak slider in the NVIDIA app. |
| Crop does nothing | The preset matches the video ratio already, or the bars are part of a letterboxed encode with a different ratio: try another preset with `Alt+a`. |
| `Alt+2` / `Alt+3` do nothing | `presets` has no entry labelled exactly `16:9` / `1.9`. |
| OSD "filter @ar_... failed" | mpv rejected the filter 3 times (driver error or a format the driver does not take). Try `pix_fmt=nv12`, update the driver, and check the mpv log (`mpv -v`). |
| "filter @ar_rtx failed" right at start | mpv is not on Direct3D 11 (e.g. `gpu-api=vulkan` or `gpu-context=winvk`): `d3d11vpp` exists only on D3D11. Set `gpu-context=d3d11`. |
| Smoothing shows "no resample" | Add `video-sync=display-resample-vdrop` (or `display-resample`) to `mpv.conf`. |

## Roadmap

- **1.1: Intel pipeline.** An Intel GPU path (Intel Video Super Resolution through `d3d11vpp` `scaling-mode=intel`) for
  laptops that run mpv on the Intel iGPU, picked automatically from the active adapter. RTX HDR has no Intel counterpart.
  See issue *Intel pipeline*.
- **1.1: Intuitive selection.** A menu / badge panel that shows every available option at once (e.g. all crop presets,
  VSR / HDR states) so you pick directly, instead of cycling one badge. See issue *Intuitive selection*.
- **1.1 (if it passes testing): automatic bar detection.** Optional, off by default: detect the bars once at the start
  of a file, snap to a standard ratio, crop once (never during playback, since every crop change rebuilds the VSR chain).
- Later, on request: per-profile power behaviour (e.g. VSR off on battery).

## Credits

`aspect-rtx.lua` grew out of the community **AutoVSR** script for mpv. It started from anthonybaldwin's
"AutoVSR + RTX HDR" and keeps its VSR / RTX HDR core: scale from display and video size (rounded down to 0.1), SDR vs
HDR source test, `x2bgr10` for 10-bit into RTX HDR and `nv12` for VSR only, the `max-luma` peak tag after RTX HDR, a
re-entry guard, and the `Ctrl+R` / `Ctrl+H` / `Ctrl+S` keys. Lineage:
- Andarwinux, whose [answer in mpv-player/mpv discussion #14804](https://github.com/mpv-player/mpv/discussions/14804#discussioncomment-10570208)
  is the source of it all: the first auto-VSR script that the AutoVSR gists grew from.
- [azumukupoe: AutoVSR for MPV](https://gist.github.com/azumukupoe/a56a78d71cf26a8f682dc06407e615db), the first
  AutoVSR gist, built from that discussion.
- [natyusha: autovsr.lua](https://gist.github.com/natyusha/e230a176d41e3092676c4e941ded406a), fork with the
  `Ctrl+Shift+R` toggle and `nv12` for 10-bit HEVC.
- [anthonybaldwin: AutoVSR + RTX HDR for MPV](https://gist.github.com/anthonybaldwin/1e49b28b49babf64f159cb793c506333),
  fork of natyusha's that added RTX Video HDR, the peak tag, options and the status key. Direct base of `aspect-rtx.lua`.
- mpv's `d3d11vpp` NVIDIA VSR / RTX Video HDR support: [mpv-player/mpv PR #14155](https://github.com/mpv-player/mpv/pull/14155).

Added in this repo: the aspect crop, Windows-HDR detection, the live display-peak tag and its store, ICC switching,
fullscreen-only mode, chain self-repair, and the panel and smoothing scripts.

## License

MIT. See [LICENSE](LICENSE). The AutoVSR gists credited above carry no license of their own; they are credited here,
not redistributed.
