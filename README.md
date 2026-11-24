# mpv dynamic scaling for NVIDIA RTX (+ calibrated headphone audio)

mpv scripts for Windows. **Video:** NVIDIA **RTX Video Super Resolution (VSR)** and **RTX Video HDR** inside mpv, with
a crop that runs *before* the upscaler, and interpolation only where the frame rate needs it. **Audio:** a calibrated
3D headphone render for surround and stereo, a headphone EQ toward a target, and a clip guard that trims each file by
one fixed amount. An on-screen card follows the signal chain and shows every setting and why it is on or off.

Version **1.2.0** ([CHANGELOG](CHANGELOG.md)). License: MIT.

Contents: [What this is for](#what-this-is-for) · [Requirements](#requirements) · [Install](#install) ·
[The pipeline each feature needs](#the-pipeline-each-feature-needs) · [Faithful and Immersive](#faithful-and-immersive) ·
[Why it sounds different](#why-it-sounds-different) · [How it works](#how-it-works) · [Features](#features) ·
[Keys and card](#keys-and-card) · [Options](#options) · [Troubleshooting](#troubleshooting) · [Limits](#limits) ·
[Credits](#credits)

## What this is for

Hear and see a recording the way its makers set it down. Nothing here adds taste: no loudness tricks, no compression,
no "enhance" EQ, no clipping. Where something is changed it undoes a known loss (a fold-down to stereo, a missing
upscale, a too-hot peak), and the amount is measured, not guessed.

## Requirements

| Needed | For |
|---|---|
| Windows 10 or 11 | everything (`d3d11vpp` is Direct3D 11 only; the audio gate reads WASAPI devices) |
| mpv 0.40 or newer, **tested on 0.42**, with `gpu-context=d3d11` and `hwdec=d3d11va-copy` | everything |
| NVIDIA RTX GPU (RTX 20 series or newer), driver 531.18+ (VSR) / 551.23+ (RTX Video HDR) | VSR and RTX Video HDR |
| NVIDIA app: *RTX Video Enhancement* -> **Super Resolution** on (and **RTX Video HDR** on) | VSR / RTX Video HDR |
| Windows HDR on (*Settings -> System -> Display -> Use HDR*) **before** mpv starts | RTX Video HDR only |
| Headphones, and the SADIE II HRTF file (see Install, step 6) | 3D audio and 3D stereo |
| ffprobe (any FFmpeg build), optional | a faster clean start (option `prebuild`) |

**Without an RTX GPU** the crop, the card, interpolation, the audio scripts and the clean start still work; VSR and
RTX HDR stay off and the card says "no RTX GPU". **Laptops with two GPUs:** keep `d3d11-adapter=NVIDIA` (in the sample
`mpv.conf`), or Windows may run mpv on the integrated GPU.

## Install

1. Open your mpv config folder: portable mpv = `portable_config\` next to `mpv.exe` (create it); installed mpv =
   `%APPDATA%\mpv\`.
2. Copy the folders `scripts\` and `script-opts\` from this repo into it. Each script works on its own; take only the
   ones you want (see [Scripts](#scripts-and-how-they-connect)).
3. Copy the lines you need from this repo's `mpv.conf` into yours. Required for video: `gpu-context=d3d11`,
   `d3d11-adapter=NVIDIA`, `hwdec=d3d11va-copy`, `video-sync=display-resample-vdrop`.
4. Remove anything else that sets `d3d11vpp`: other "auto VSR" scripts, the old `mpv-dynamic-scaling.lua`, or a
   `vf=d3d11vpp...` line.
5. Optional: if ffprobe is not on your `PATH`, put its full path in `script-opts\aspect_rtx.conf`
   (`prebuild=C:/path/to/ffprobe.exe`).
6. 3D audio: download the **SADIE II** HRTF database from the University of York
   ([SADIE II](https://www.york.ac.uk/sadie-project/database.html)), subject **D2** (KEMAR dummy head), the **48 kHz**
   HRIR set as a `.sofa` file, and save it as `hrtf\SADIE_II_D2_KEMAR_48K.sofa` in your config folder (or point option
   `binaural-sofa` at it). It is not included here: check its licence on the SADIE site. Without it 3D audio stays off
   and the card says "no HRTF file".
7. 3D audio: put your headphone endpoint names in `script-opts\binaural.conf` (`headphones=`; `mpv --audio-device=help`
   lists them). 3D audio switches on by itself only on those devices.
8. Headphone EQ (optional): no profile ships. Add your headphone's AutoEQ file, see
   [EQ: bring your own headphone profile](#eq-bring-your-own-headphone-profile). Without one the EQ stays out of the way.
9. Play a video **fullscreen** and move the pointer to the top-right corner: the card shows each stage, e.g. VSR
   "On 1.5x", or the reason it is off.

## The pipeline each feature needs

Each feature works only if the whole path behind it is clean. Check yours:

**Audio**
- [ ] Windows audio enhancements **off** for the output device (*Sound settings -> device -> Audio enhancements: Off*).
- [ ] Windows spatial sound **off**: Dolby Atmos for Headphones, DTS Headphone:X, Windows Sonic. They re-process the
      already rendered signal after mpv: double virtualisation, added noise and colour.
- [ ] Output: a 2-channel endpoint (headphones); shared mode is fine. mpv folds or renders to 2 channels itself.
- [ ] mpv volume 100 % (the sample `mpv.conf` sets it); set loudness with the system or device volume, so the peak
      trim keeps its headroom exact.
- [ ] Headphones for 3D audio: the virtual speakers assume one ear per channel. On speakers it stays off by itself.

**Video**
- [ ] NVIDIA RTX GPU, driver 551.23+, NVIDIA app: Super Resolution (and RTX Video HDR) on.
- [ ] Fullscreen for VSR and RTX HDR ([why](#why-off-in-a-window)).
- [ ] Windows HDR on *before* mpv starts, for RTX Video HDR.
- [ ] `video-sync=display-resample-vdrop` (in the sample `mpv.conf`): frames timed to the display's refresh.

### What breaks a feature

| Feature | Broken by |
|---|---|
| 3D audio, EQ, peak trim | Windows spatial sound or device "enhancements" (they re-process after mpv); a multichannel endpoint (mpv no longer folds); mpv volume above 100 % |
| 3D audio | no HRTF file; the device is not on your `headphones` list (by design: speakers get the plain fold) |
| VSR | a window (by design); software decoding; another script using `d3d11vpp`; a small scale (below 1.3x, "scale too small"); a GPU too slow for a large picture (turns off by itself: "VSR off: stutter") |
| RTX HDR | Windows HDR off at mpv start; an HDR source (never re-mapped) |
| Smooth | a display refresh mpv cannot read; heavy files (turns off by itself) |

## Defaults and why

Out of the box the player shows the picture and plays the sound as they were made. Everything that changes them is
opt-in. NVIDIA-only features switch themselves off on other GPUs; nothing fails.

| Feature | Default | Why | Turn it on |
|---|---|---|---|
| Peak guard | on, pre-roll 0 | only ever lowers the level, and only when a file would clip; safe for everyone | on already (`peak-preroll_max=8` holds short files until measured) |
| RTX VSR upscaling | on with an NVIDIA RTX GPU (scale >= 1.3), else off | sharper upscale where the GPU can do it; silent no-op elsewhere | automatic; `aspect_rtx-vsr=no` turns it off |
| RTX HDR | off | changes the look of SDR video | `Alt+h` or the card; `aspect_rtx-hdr=yes` |
| Crop black bars | off | the frame as made | the card's Crop row; `aspect_rtx-crop=auto` |
| Show as | Fit | the picture as it is | the card's Show row (Half / Fill) |
| Motion smoothing | off | frame blending changes how motion looks | `Alt+i`; `smooth-default=auto` |
| 3D audio (headphones) | off until you add a SOFA file | needs an HRTF; see Install | add the SOFA file (Install) |
| Headphone EQ | off, no profile shipped | a correction is right only for the headphone it was measured for | your own AutoEQ profile (see EQ); `Alt+e` |

The card's **Make default** button saves your current choices as the start-up default; **Reset default** goes back to
these.

## Faithful and Immersive

Every feature is its own switch. The card's **Preset** row sets them in one click; changing any switch afterwards
makes it **Custom**.

| | Faithful | Immersive |
|---|---|---|
| Video | original frame (Crop Off, Show as Fit), VSR as a plain upscaler, no RTX HDR, no interpolation | Crop Auto (burned-in bars removed), Show as Fill, VSR, RTX HDR in fullscreen, Smooth Auto |
| Audio | exact stereo fold, headphone EQ, peak trim | + 3D audio (surround on virtual speakers) and 3D stereo |

Faithful is the floor; the immersive features sit on top of it and can be mixed. `rtx_panel-preset=faithful` (or
`immersive`) applies a preset at the first file; the default `custom` keeps your own settings.

## Why it sounds different

The chain adds nothing to make the change happen. It removes what usually stands between the file and your ears:

- **Nothing re-processes after mpv.** With Windows effects and spatial sound off, the samples mpv sends are the samples
  the headphones play. Most "Atmos for headphones" layers re-render an already rendered or folded signal; their colour
  and noise are gone here.
- **Surround gets a calibrated 3D render.** A surround track plays on virtual loudspeakers at their standard positions
  (ITU-R BS.775) through measured head-related responses (a dummy-head HRTF set). Each speaker is equalised so its
  power per third-octave matches its share in the plain stereo fold, and the level matches the fold: the mix keeps its
  balance, but the channels sit around you instead of being summed into two.
- **Stereo gets speakers in front.** A stereo track plays on two virtual speakers at +-30 degrees, the way it was mixed,
  instead of inside your head; an EQ keeps its timbre and loudness the same as plain stereo. Instruments keep their
  place, and their overtones are not smeared together.
- **The headphone EQ corrects the headphone, not the music.** It moves the headphone's measured response toward a
  neutral target, so the mix's own balance comes through. It is not a taste curve.
- **No clipping.** Folds and 3D renders can add peaks above full scale. The peak guard measures each file and lowers it
  by one fixed amount, just enough to stay under -1 dBTP. No limiter, no compression: the dynamics are the recording's.
- **Music and film alike.** A stereo music video gets the virtual front speakers + EQ + peak guard; a film gets the
  surround render. Same chain, same rules.

## How it works

```
VIDEO  decode (d3d11va-copy)
         -> crop            the picture cut to a ratio (Auto: burned-in bars)      aspect-rtx
         -> show as         Fit | Half | Fill: sides cut for the screen             aspect-rtx
         -> RTX VSR / HDR   NVIDIA upscale to the screen; SDR -> HDR (d3d11vpp)     aspect-rtx
         -> renderer        ICC on SDR displays, HDR output on HDR ones             mpv, ICC set by aspect-rtx
         -> frame timing    display-resample + interpolation on uneven cadence      mpv.conf + smooth
AUDIO  decode
         -> 3D audio        surround -> virtual speakers; stereo -> 3D stereo       binaural
         -> headphone EQ    headphone response -> target (your profile)             eq
         -> peak trim       one static negative trim per file (<= -1 dBTP)          peak
         -> output          2-channel endpoint, nothing after mpv                   Windows (effects off)
```

What you can notice where the stages meet:
- **The crop sets the VSR size.** VSR upscales the cropped picture, so a crop raises the scale factor
  (1920x800 cropped to 1520x800 on a 2880x1620 screen = 1.8x).
- **VSR from 1.3x up.** Below that the upscale costs GPU load for almost no visible gain; the card says "scale too
  small". If VSR makes playback stutter (a large picture on a slow GPU), it turns off for that file.
- **RTX HDR needs an HDR display.** It runs only when Windows HDR was on when mpv started.
- **A change rebuilds the chain.** Going fullscreen, changing the crop, or switching VSR/HDR rebuilds the filter chain:
  a short pause, sometimes a dropped frame.
- **An unmeasured file is measured while you watch.** When a file opens with no measurement, a fast background pass
  (below-normal priority; a song takes seconds, a film a few minutes) measures the whole file on the path you hear.
  Until it completes the file plays with a safe default trim; then the measured trim is applied at once, as a 0.2 s
  ramp, without a click or a position change. Playing, pausing and seeking go on as usual. **Measure folder** measures
  a whole folder ahead.

### Why off in a window

By default VSR and RTX HDR run in fullscreen only; a window shows the plain picture (the crop still applies). VSR
upscales to the screen size even in a window, so in a window it pays the full cost and the result is shrunk again (no
gain); an HDR window looks far too contrasty next to the other (SDR) windows on the desktop, and HDR matters for a
fullscreen watch.

## Scripts and how they connect

| Script / file | Owns (only it writes) | Talks through |
|---|---|---|
| `scripts/aspect-rtx.lua` | the video filter chain (`vf` labels `@ar_crop`, `@ar_rtx`, `@ar_luma`), `icc-profile-auto`, the start pause | publishes `user-data/aspect_rtx`; takes `set-crop`, `set-show`, `set-vsr`, `set-hdr-mode` |
| `scripts/smooth.lua` | `interpolation`, `tscale` | publishes `user-data/smooth`; takes `set-mode` |
| `scripts/binaural.lua` | audio filter `@binaural` (3D audio / 3D stereo) | publishes `user-data/binaural`; takes `set-binaural`, `set-binaural-stereo` |
| `scripts/eq.lua` | audio filter `@kzcal` (headphone EQ; the label is historical) | publishes `user-data/eq` (only with a profile); takes `set-eq`, `set-profile` |
| `scripts/peak.lua` | audio filter `@peak` (trim) and its meter; the measurement store | publishes `user-data/peak`; takes `set-peak`, `peak-analyze-folder` |
| `scripts/rtx-panel.lua` | only its own card (no playback setting) | reads the `user-data/*` above; sends the script-messages above |
| `mpv.conf` | base settings | `script-opts-append=` lines override the `.conf` files |

Load order does not matter, and no two scripts write the same setting. Without a script the card simply has no row for
it.

## Features

| Feature | Default | Applies automatically when | Change it |
|---|---|---|---|
| RTX VSR (upscale) | on | fullscreen, RTX GPU, hardware decoding, scale 1.3x or more | `Ctrl+Shift+R`, card **VSR**, option `vsr` |
| VSR stutter guard | on | VSR running and >= 10 dropped + delayed frames in 4 s: VSR off for this file | options `vsr_guard*` |
| RTX Video HDR | fullscreen | RTX GPU, SDR video, Windows HDR on | `Ctrl+Shift+H`, card **RTX HDR**, option `hdr_mode` |
| Crop | Auto (sample config) | Auto: black bars burned into the picture, detected once per file; or a preset ratio | `Alt+a`, `Alt+0..3`, card **Crop**, option `crop` |
| Show as | Fit | Fill / Half cut the sides of a picture wider than the screen | card **Show as**, option `show` |
| HDR peak tag | live display peak | RTX HDR runs | option `hdr_peak` |
| ICC colour profile | managed | SDR display and RTX HDR not running | option `icc_sdr` |
| Clean start | on | every file starts paused until the chain is ready | option `prebuild` |
| Interpolation | auto | the frame rate does not divide into the refresh (e.g. 25 fps on 60 Hz) | `Alt+i`, card **Smooth**, option `smooth-default` |
| 3D audio | on | a surround track (codecs in `codecs`, default TrueHD) on a listed headphone device | `Alt+u`, card **3D audio**, options `binaural-*` |
| 3D stereo | off | a stereo track on a listed headphone device | `Alt+U`, card **3D audio**, option `binaural-stereo` |
| Headphone EQ | off | you turn it on and have a profile in `script-opts/eq/` | `Alt+e`, card **EQ** (Off \| your profiles), options `eq-*` |
| Peak trim | on | every file: measured peak, or a safe default until the measurement pass completes | `Alt+p`, card **Peak trim**, options `peak-*` |
| Measurement pass | on | a file opens with no measurement; also on demand | `Alt+P`, card **Measure now**, option `peak-auto_measure` |

### EQ: bring your own headphone profile

No profile ships: an EQ corrects one headphone model toward a neutral target, and is wrong for any other.

1. Open [AutoEQ](https://github.com/jaakkopasanen/AutoEq) and find your headphone's results.
2. Download its `... ParametricEQ.txt` (or `... GraphicEQ.txt`) into `script-opts\eq\` (make the folder). Rename it if
   you like: the file name is the name on the card.
3. Restart mpv. The card's **EQ** row now shows Off | your profile; click it, or press `Alt+e`. For EQ on at start,
   set `eq-default=yes` in `mpv.conf`.

The file is used as written: its `Preamp:` line (the negative of its largest boost, so the EQ cannot clip) and its
filters (`PK`, `LSC`, `HSC`) or its `GraphicEQ:` line. Several files = several profiles; `eq-profile=<name>` picks the
one `Alt+e` uses.

### Measuring ahead

Until a file is measured the peak guard uses a safe default trim (renderer -13.5 dB, fold -8.5 dB, 3D stereo -6 dB,
plain stereo 0 dB); the measurement pass replaces it within seconds (a song) or minutes (a film). To measure ahead
instead: the card's **Measure folder** (peak row, More), or

```
mpv --idle=once --script-opts=peak-analyze=C:/path/to/folder
```

measures every media file in the folder in fast headless runs, one at a time, waiting while a file plays.
`peak-store_dir=media` keeps the results beside the media (a `.mpv-measure` folder) instead of mpv's cache folder.

## Keys and card

| Key / card | Action |
|---|---|
| Pointer to the top-right corner | Shows the card; it hides 0.4 s after the pointer leaves. Click a badge to choose. |
| `Alt+b` / **Pin** | Keep the card on screen. **More** / **Less** = every option / only what is on. |
| `Alt+a` | Cycle crop: off -> each preset -> off |
| `Alt+0` or `Alt+1` | Crop off |
| `Alt+2` / `Alt+3` | Preset labelled `16:9` / `1.9` |
| `Ctrl+Shift+R` (or `Ctrl+R`) | VSR on / off |
| `Ctrl+Shift+H` (or `Ctrl+H`) | RTX Video HDR on / off |
| `Ctrl+Shift+S` (or `Ctrl+S`) / **Info** | Status: filter chain, decoder, display mode |
| `Alt+i` | Interpolation: auto -> on -> off |
| `Alt+u` / `Alt+U` | 3D audio / 3D stereo on / off for this file |
| `Alt+e` | Headphone EQ on / off |
| `Alt+p` | Peak trim on / off |
| `Alt+P` | Measure this file now (applied when done) |

Badges: **blue fill** = chosen and working; **blue outline** = chosen but waiting, with the reason in grey
("windowed", "scale too small", "no HRTF file", "speakers", ...). A small line at the top right shows
background work ("measuring 40 %") and then what is applied ("3D · EQ · PK -2.4"); `rtx_panel-applied_marks=hide`
turns it off.

Rebind in `input.conf`: `KEY script-binding aspect_rtx/ar-vsr` (names `ar-cycle`, `ar-off`, `ar-1`, `ar-2`, `ar-3`,
`ar-vsr`, `ar-hdr`, `ar-status`; `smooth/toggle`; `rtx_panel/toggle`), or choose directly with
`KEY script-message set-crop auto` (`set-vsr yes|no`, `set-hdr-mode off|fullscreen|always`, `set-mode auto|on|off`,
`set-binaural yes|no`, `set-eq yes|no`, `set-profile <name>` (to `eq`), `set-peak yes|no`, `peak-measure-now`).

## Options

In `mpv.conf` as `script-opts-append=<script>-<option>=<value>`, or in `script-opts\<script>.conf` as
`<option>=<value>`.

| Option | Default | Meaning |
|---|---|---|
| `aspect_rtx-presets` | `16:9,1.9` | Crop ratios, decimal or W:H. Sample config: `1.9,1.85,1.78,2.39,16:9`. |
| `aspect_rtx-crop` | `auto` | Crop at start: `auto` (burned-in bars), `off`, or a preset label. |
| `aspect_rtx-show` | `fit` | Show as at start: `fit`, `half`, `fill`, or a preset label. |
| `aspect_rtx-vsr` | `yes` | VSR wanted at start. |
| `aspect_rtx-vsr_min_scale` | `1.3` | No VSR below this scale. |
| `aspect_rtx-vsr_guard`, `-vsr_guard_frames`, `-vsr_guard_window` | `yes`, `10`, `4` | Stutter guard: VSR off for the file after this many dropped + delayed frames in this many seconds. |
| `aspect_rtx-hdr_mode` | `fullscreen` | RTX HDR: `off`, `fullscreen`, `always`. |
| `aspect_rtx-hdr_peak` | `auto` | RTX HDR peak tag: `auto` = live display peak, or a number of nits. |
| `aspect_rtx-hdr_display` | `auto` | `auto` = detect the display's HDR mode; `yes` / `no` to force it. |
| `aspect_rtx-icc_sdr` | `auto` | ICC on SDR displays: `auto` = only if `icc-profile-auto` was on, `yes`, `no`. |
| `aspect_rtx-prebuild` | `ffprobe` | ffprobe for the clean start: `ffprobe` (from `PATH`), a full path, or empty = off. |
| `aspect_rtx-pix_fmt` | `auto` | Force the format into the RTX filter: `nv12`, `p010`, `x2bgr10`. |
| `smooth-default` | `auto` | Interpolation at start: `auto`, `on`, `off`. |
| `smooth-heavy_mpxs` | `250` | `auto` stays off above this decoded pixel rate (Mpx/s); `0` = no limit. |
| `binaural-headphones` | empty | Headphone endpoints (parts of the device name, `;` separated). Empty = 3D audio off everywhere. |
| `binaural-codecs` | `truehd` | Surround codecs 3D audio renders; `*` = every multichannel codec. |
| `binaural-stereo` | `no` | 3D stereo at start. |
| `binaural-trim`, `binaural-stereo_trim` | `0.3`, `0` | Static level trim in dB (the defaults are loudness-matched to plain stereo). |
| `binaural-sofa` | `~~/hrtf/SADIE_II_D2_KEMAR_48K.sofa` | HRTF file. |
| `eq-default` | `no` | EQ on at start (needs a profile). |
| `eq-profile` | empty | Profile for `Alt+e` / `set-eq yes`; empty = the first by name. |
| `eq-dir` | `~~/script-opts/eq` | Folder of profile files (`*.txt`, AutoEQ ParametricEQ or GraphicEQ). |
| `peak-enabled` | `yes` | Peak trim on at start. |
| `peak-target` | `-1` | Ceiling in dBTP. |
| `peak-store_dir` | empty | Where measurements live: empty = mpv's cache folder, `media` = beside each file, or a folder path. |
| `peak-auto_measure` | `yes` | Measure an unmeasured file in the background when it opens; apply the trim when done. |
| `peak-preroll_max` | `0` | Pre-roll: a file up to this many minutes with no measurement holds its start until measured (a song waits about 3 s), so the exact trim holds from the first sample. Pressing play skips the wait. `0` = off. |
| `peak-lookahead` | `0` | Minutes to measure at file start before playback (`0` = off). |
| `rtx_panel-preset` | `custom` | Preset applied at the first file: `faithful`, `immersive`, `custom`. |
| `rtx_panel-view` | `compact` | Card view at start: `compact` or `detail`. |
| `rtx_panel-leave_grace`, `rtx_panel-pinned` | `0.4`, `no` | Seconds the card stays after the pointer leaves; card always shown. |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| VSR shows "windowed" or is off | VSR runs in fullscreen only, or it was switched off | Go fullscreen; press `Ctrl+Shift+R`; turn Super Resolution on in the NVIDIA app. |
| VSR "scale too small" | The picture is already almost screen size | Nothing to fix: the gain there is too small for the load. Lower `vsr_min_scale` to force it. |
| "VSR off: stutter" | The GPU cannot keep up with VSR on this picture | The next file starts with VSR again. A crop (smaller input) or a lower display resolution helps. |
| "no RTX GPU" | mpv runs on another GPU (e.g. a laptop's integrated GPU) | Add `d3d11-adapter=NVIDIA` to `mpv.conf`, or set mpv to *High performance* in Windows *Graphics settings*. |
| RTX HDR shows "Windows HDR off" | Windows HDR was off when mpv started | Turn Windows HDR on, then restart mpv. |
| 3D audio "no HRTF file" | The SOFA file is missing | Install step 6. |
| 3D audio off on headphones | The device is not on the `headphones` list | Add its name to `script-opts\binaural.conf`. |
| Audio sounds doubly "spatial" or coloured | Windows spatial sound or enhancements are on | Turn them off ([pipeline](#the-pipeline-each-feature-needs)). |
| OSD "filter @ar_... failed" | The driver rejected the filter, or mpv is not on Direct3D 11 | Set `gpu-context=d3d11`; try `aspect_rtx-pix_fmt=nv12`; update the driver. |

## Limits

- Windows and Direct3D 11 only. VSR and RTX HDR need an NVIDIA RTX GPU; Intel and AMD upscalers are not used.
- mpv reads the display's HDR mode when it starts: turning Windows HDR on or off during playback needs a restart.
- The scripts never change Windows settings and run no program except the optional ffprobe (and mpv itself for
  **Measure folder**).
- VSR and RTX HDR raise GPU power and fan noise; on battery, switch them off with `Ctrl+Shift+R` / `Ctrl+Shift+H`.
- HDR10 / HLG / Dolby Vision video is never sent through RTX HDR; mpv shows it as it is.
- 3D audio uses one generic dummy-head HRTF; it is not personalised to your ears.
- Only one script may use `d3d11vpp`. Tested on one laptop RTX GPU with one display; multi-display setups are untested.

## Credits

`aspect-rtx.lua` keeps the VSR / RTX HDR core of the community **AutoVSR** scripts:
[Andarwinux's answer in mpv discussion #14804](https://github.com/mpv-player/mpv/discussions/14804#discussioncomment-10570208),
[azumukupoe: AutoVSR](https://gist.github.com/azumukupoe/a56a78d71cf26a8f682dc06407e615db),
[natyusha: autovsr.lua](https://gist.github.com/natyusha/e230a176d41e3092676c4e941ded406a) and
[anthonybaldwin: AutoVSR + RTX HDR](https://gist.github.com/anthonybaldwin/1e49b28b49babf64f159cb793c506333) (direct base),
built on mpv's `d3d11vpp` RTX support ([mpv PR #14155](https://github.com/mpv-player/mpv/pull/14155)).
3D audio uses FFmpeg's `sofalizer` filter and the **SADIE II** HRTF database (University of York; not redistributed
here). The headphone EQ reads [AutoEQ](https://github.com/jaakkopasanen/AutoEq) ParametricEQ and GraphicEQ results.
`legacy/` holds this repo's first version; do not load it together with `aspect-rtx.lua`.

## License

MIT. See [LICENSE](LICENSE). The AutoVSR gists above carry no license of their own; they are credited, not
redistributed. The SADIE II HRTF file is not part of this repo.
