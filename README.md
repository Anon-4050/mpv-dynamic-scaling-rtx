# mpv dynamic scaling for NVIDIA RTX

mpv scripts for Windows that run NVIDIA **RTX Video Super Resolution (VSR)** and **RTX Video HDR** inside mpv.
A film can be cropped to a ratio you pick *before* the upscaler, so VSR does the whole enlargement.
An on-screen card shows every setting and why it is on or off; interpolation blends frames only when the frame rate needs it.

Version **1.1.0** ([CHANGELOG](CHANGELOG.md)). License: MIT.

## Requirements

| Needed | For |
|---|---|
| Windows 10 or 11 | everything (`d3d11vpp` is Direct3D 11 only) |
| mpv 0.40 or newer, **tested on 0.42**, with `gpu-context=d3d11` and `hwdec=d3d11va-copy` | everything |
| NVIDIA RTX GPU (RTX 20 series or newer), driver 531.18+ (VSR) / 551.23+ (RTX Video HDR) | VSR and RTX Video HDR |
| NVIDIA app: *RTX Video Enhancement* -> **Super Resolution** on (and **RTX Video HDR** on) | VSR / RTX Video HDR |
| Windows HDR on (*Settings -> System -> Display -> Use HDR*) **before** mpv starts | RTX Video HDR only |
| ffprobe (any FFmpeg build), optional | a faster clean start (option `prebuild`) |

**Without an RTX GPU** the crop, the panel, interpolation and the clean start still work; VSR and RTX HDR stay off and
the panel says "no RTX GPU". **Laptops with two GPUs:** keep `d3d11-adapter=NVIDIA` (in the sample `mpv.conf`), or
Windows may run mpv on the integrated GPU.

## Install

1. Open your mpv config folder: portable mpv = `portable_config\` next to `mpv.exe` (create it); installed mpv =
   `%APPDATA%\mpv\`.
2. Copy the folders `scripts\` and `script-opts\` from this repo into it.
3. Copy the lines you need from this repo's `mpv.conf` into yours. Required: `gpu-context=d3d11`,
   `d3d11-adapter=NVIDIA`, `hwdec=d3d11va-copy`, `video-sync=display-resample-vdrop`.
4. Remove anything else that sets `d3d11vpp`: other "auto VSR" scripts, the old `mpv-dynamic-scaling.lua`, or a
   `vf=d3d11vpp...` line.
5. Optional: if ffprobe is not on your `PATH`, put its full path in `script-opts\aspect_rtx.conf`
   (`prebuild=C:/path/to/ffprobe.exe`).
6. Play a video **fullscreen** and move the pointer to the top-right corner: the card shows VSR "On" with its scale
   (e.g. "On 1.5x"), or the reason it is off.

## How it works

```
decode (d3d11va-copy)
  -> crop            the picture cut to a preset ratio                     aspect-rtx
  -> RTX VSR / HDR   NVIDIA upscale to the screen; SDR -> HDR (d3d11vpp)    aspect-rtx
  -> renderer        ICC profile on SDR displays, HDR output on HDR ones   mpv, ICC set by aspect-rtx
  -> display         size and HDR mode, read by mpv when it starts         mpv
  -> frame timing    display-resample + interpolation on uneven cadence   mpv.conf + smooth
```

What you can notice where the stages meet:
- **The crop sets the VSR size.** VSR upscales the cropped picture, so a crop raises the scale factor
  (1920x800 cropped to 1520x800 on a 2880x1620 screen = 1.8x).
- **RTX HDR needs an HDR display.** It runs only when Windows HDR was on when mpv started; turning HDR on later needs
  an mpv restart.
- **A change rebuilds the chain.** Going fullscreen, changing the crop, or switching VSR/HDR rebuilds the filter chain:
  a short pause, sometimes a dropped frame. Interpolation does not count drops caused by such a rebuild.
- **Fullscreen only.** By default VSR and RTX HDR run in fullscreen only; a window shows the plain picture (the crop
  still applies).

## Scripts and how they connect

```
               keys / mouse                     keys
                    |                             |
              rtx-panel.lua  --script-message-->  aspect-rtx.lua --> filter chain (vf), ICC, start pause
              (card, reads)  --script-message-->  smooth.lua     --> interpolation, tscale
                    ^                             |
                    +------ user-data/aspect_rtx, user-data/smooth (status) <---+
   mpv.conf: base settings          script-opts/aspect_rtx.conf: aspect-rtx options
```

| Script / file | Owns (only it writes) | Reads | Talks through |
|---|---|---|---|
| `scripts/aspect-rtx.lua` | the filter chain (`vf` labels `@ar_crop`, `@ar_rtx`, `@ar_luma`), `icc-profile-auto`, the start pause (and `hwdec` `d3d11va` -> `d3d11va-copy` when a crop needs it) | video size and format, display size, fullscreen, mpv's display read, ffprobe (optional) | publishes `user-data/aspect_rtx`; takes `set-crop`, `set-vsr`, `set-hdr` |
| `scripts/smooth.lua` | `interpolation`, `tscale` | refresh rate, video frame rate, `video-sync`, dropped frames | publishes `user-data/smooth`; takes `set-mode` |
| `scripts/rtx-panel.lua` | only its own card (no playback setting) | `user-data/aspect_rtx`, `user-data/smooth` | sends the script-messages above |
| `mpv.conf` | base settings (`gpu-context`, `hwdec`, `video-sync`, ...) | | `script-opts-append=` lines override the `.conf` files |
| `script-opts/aspect_rtx.conf` | aspect-rtx options (e.g. ffprobe path) | | |

The card also has a Windows HDR row and an EQ row, but they show only when separate scripts for those are installed
(none is included here).

Which scripts you need:
- **aspect-rtx.lua alone** gives VSR, RTX HDR, the crop, ICC handling and the clean start, all on keys.
- **+ smooth.lua** adds interpolation (`Alt+i`). It works on its own too.
- **+ rtx-panel.lua** adds the card. It only shows and sends: without aspect-rtx it has no Crop / VSR / RTX HDR rows,
  without smooth no Interpolation row.

Load order does not matter: mpv loads every script in `scripts\`, and the card fills in as soon as the others
publish their status. No two scripts write the same setting.

## Features

| Feature | Default | Applies automatically when | Change it |
|---|---|---|---|
| RTX VSR (upscale) | on | fullscreen, RTX GPU, hardware decoding, picture smaller than the screen | `Ctrl+Shift+R`, card **VSR**, option `vsr` |
| RTX Video HDR | on | fullscreen, RTX GPU, SDR video, Windows HDR on | `Ctrl+Shift+H`, card **RTX HDR**, option `hdr` |
| Crop presets | preset in `start` (sample config: 1.9) | a preset (the `start` one or one you pick) crops every file to its ratio; **Auto** crops to the screen's ratio, only when the picture differs from it by more than 2 % | `Alt+a`, `Alt+0..3`, card **Crop**, options `presets`, `start` |
| HDR peak tag | live display peak | RTX HDR runs: tells the renderer the display's real brightness | option `hdr_peak` |
| ICC colour profile | managed | SDR display and RTX HDR not running (off on HDR displays) | option `icc_sdr` |
| Clean start | on | every file starts paused until the chain is ready, so the first frame is upscaled and audio is in sync | option `prebuild` |
| Interpolation | auto | the frame rate does not divide into the refresh rate (e.g. 25 fps on 60 Hz); off for heavy files or when frames drop | `Alt+i`, card **Interpolation**, option `smooth-default` |

Crop on a 16:9 screen with `start=1.9`: every file is cropped to 1.9:1 at start (2.39:1, 16:9 and 4:3 alike). With
`start=auto` (or the card's **Auto**) the crop follows the screen: a 2.39:1 or 4:3 file is cropped to 16:9, a 16:9 file
is left as is (the card says "fits the display"). Pick a preset (key or card) to crop to that ratio, e.g. a 16:9 file
with black bars burned in -> 2.39 (in the sample `mpv.conf` presets) removes the bars. Your pick stays for the
following files. A portrait (rotated phone) clip is not cropped at start.

## Keys and card

| Key / card | Action |
|---|---|
| Pointer to the top-right corner | Shows the card; it hides 0.4 s after the pointer leaves. Click a badge to choose. |
| `Alt+b` / **Pin** | Keep the card on screen |
| `Alt+a` | Cycle crop: off -> each preset -> off |
| `Alt+0` or `Alt+1` | Crop off |
| `Alt+2` / `Alt+3` | Preset labelled `16:9` / `1.9` |
| `Ctrl+Shift+R` (or `Ctrl+R`) | VSR on / off |
| `Ctrl+Shift+H` (or `Ctrl+H`) | RTX Video HDR on / off |
| `Ctrl+Shift+S` (or `Ctrl+S`) / **Info** | Status: filter chain, decoder, display mode |
| `Alt+i` | Interpolation: auto -> on -> off |

Badges: **blue fill** = chosen and working; **blue outline** = chosen but waiting, with the reason under the row name
("windowed", "HDR source", "fits the display", "no RTX GPU", ...).
Rebind in `input.conf`: `KEY script-binding aspect_rtx/ar-vsr` (names `ar-cycle`, `ar-off`, `ar-1`, `ar-2`, `ar-3`, `ar-vsr`,
`ar-hdr`, `ar-status`; `smooth/toggle`; `rtx_panel/toggle`), or choose directly with
`KEY script-message-to aspect_rtx set-crop 1.9` (or `auto` / `original`; `set-vsr yes|no`, `set-hdr yes|no`; `smooth set-mode auto|on|off`).

## Options

In `mpv.conf` as `script-opts-append=<option>=<value>`, or in `script-opts\aspect_rtx.conf` as `<name>=<value>`
without the `aspect_rtx-` prefix.

| Option | Default | Meaning |
|---|---|---|
| `aspect_rtx-presets` | `16:9,1.9` | Crop ratios, decimal or W:H. Sample config: `1.9,1.85,1.78,2.39,16:9`. |
| `aspect_rtx-start` | `16:9` | Crop at start: a preset label, `auto` (the screen's ratio, only when the picture differs) or `original`. |
| `aspect_rtx-ratio_tol` | `0.02` | **Auto** does not crop when picture and screen ratios differ by 2 % or less. |
| `aspect_rtx-clamp` | `no` | `yes` = **Auto** only trims the sides of pictures wider than the screen (4:3 is left as is). Presets always use their exact ratio. |
| `aspect_rtx-vsr`, `aspect_rtx-hdr` | `yes`, `yes` | VSR / RTX HDR wanted at start. |
| `aspect_rtx-fullscreen_only` | `yes` | VSR / RTX HDR only in fullscreen. |
| `aspect_rtx-hdr_peak` | `auto` | RTX HDR peak tag: `auto` = live display peak, or a number of nits. |
| `aspect_rtx-hdr_display` | `auto` | `auto` = detect the display's HDR mode; `yes` / `no` to force it. |
| `aspect_rtx-icc_sdr` | `auto` | ICC on SDR displays: `auto` = only if `icc-profile-auto` was on, `yes` = always, `no` = never touch it. |
| `aspect_rtx-prebuild` | `ffprobe` | ffprobe for the clean start: `ffprobe` (from `PATH`), a full path, or empty = off. |
| `aspect_rtx-pix_fmt` | `auto` | Force the format into the RTX filter: `nv12`, `p010`, `x2bgr10`. |
| `aspect_rtx-peak_store`, `aspect_rtx-display_store` | files in mpv's cache folder | Last display peak / size and HDR mode, for a faster start; empty = do not store. |
| `smooth-default` | `auto` | Interpolation at start: `auto`, `on`, `off`. |
| `smooth-heavy_mpxs` | `250` | `auto` stays off above this decoded pixel rate (Mpx/s; e.g. 4K at 50 fps); `0` = no limit. |
| `smooth-heavy_bits` | `0` | ... and only when the bit depth is at least this (e.g. `10`); `0` = any depth. |
| `smooth-drop_limit`, `smooth-drop_window` | `4`, `10` | `auto` turns off for the file after this many dropped frames within this many seconds. |
| `smooth-grace` | `3` | Seconds after a start or seek in which dropped frames are not counted. |
| `rtx_panel-leave_grace` | `0.4` | Seconds the card stays after the pointer leaves. |
| `rtx_panel-pinned` | `no` | Card always shown. |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| VSR shows "windowed" or is off | VSR runs in fullscreen only, or it was switched off | Go fullscreen; press `Ctrl+Shift+R`; turn Super Resolution on in the NVIDIA app. |
| "no RTX GPU" | mpv runs on another GPU (e.g. a laptop's integrated GPU) | Add `d3d11-adapter=NVIDIA` to `mpv.conf`, or set mpv to *High performance* in Windows *Graphics settings*. |
| Picture not cropped at start | The card says "fits the display": with **Auto** a file that already has the screen's ratio is left as is | Pick a preset (key or click its badge). Bars burned into a file are not detected automatically. |
| RTX HDR shows "Windows HDR off" | Windows HDR was off when mpv started | Turn Windows HDR on, then restart mpv. |
| HDR looks dim or washed out | Another script or `mpv.conf` forces `icc-profile-auto=yes` on an HDR display, or the display reports a wrong peak | Remove that line (aspect-rtx manages ICC); set `aspect_rtx-hdr_peak=<nits>`. |
| OSD "filter @ar_... failed" | The driver rejected the filter, or mpv is not on Direct3D 11 | Set `gpu-context=d3d11`; try `aspect_rtx-pix_fmt=nv12`; update the driver. |

## Limits

- Windows and Direct3D 11 only. VSR and RTX HDR need an NVIDIA RTX GPU; Intel and AMD upscalers are not used.
- Black bars burned into the video are not detected; pick the preset that matches the film (e.g. 2.39) to remove them.
- mpv reads the display's HDR mode when it starts: turning Windows HDR on or off during playback needs a restart.
- The scripts never change Windows settings and run no program except the optional ffprobe.
- VSR and RTX HDR raise GPU power and fan noise; on battery, switch them off with `Ctrl+Shift+R` / `Ctrl+Shift+H`.
- HDR10 / HLG / Dolby Vision video is never sent through RTX HDR; mpv shows it as it is.
- Only one script may use `d3d11vpp`. Tested on one laptop RTX GPU with one display; multi-display setups are untested.

## Credits

`aspect-rtx.lua` keeps the VSR / RTX HDR core of the community **AutoVSR** scripts:
[Andarwinux's answer in mpv discussion #14804](https://github.com/mpv-player/mpv/discussions/14804#discussioncomment-10570208),
[azumukupoe: AutoVSR](https://gist.github.com/azumukupoe/a56a78d71cf26a8f682dc06407e615db),
[natyusha: autovsr.lua](https://gist.github.com/natyusha/e230a176d41e3092676c4e941ded406a) and
[anthonybaldwin: AutoVSR + RTX HDR](https://gist.github.com/anthonybaldwin/1e49b28b49babf64f159cb793c506333) (direct base),
built on mpv's `d3d11vpp` RTX support ([mpv PR #14155](https://github.com/mpv-player/mpv/pull/14155)).
Added here: the crop and its ratio rules, HDR-mode detection, the clean start, the live peak tag, ICC handling,
chain self-repair, the card and the interpolation script. `legacy/` holds this repo's first version; do not load it
together with `aspect-rtx.lua`.

## License

MIT. See [LICENSE](LICENSE). The AutoVSR gists above carry no license of their own; they are credited, not redistributed.
