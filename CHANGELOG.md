# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/)
(major = breaking config or key changes, minor = new features, patch = fixes). Each release has a git tag `vX.Y.Z`.

## [Unreleased]
- Planned: Intel GPU pipeline.

## [1.3.0] - 2026-11-25
Scripts: `aspect-rtx.lua` v4.8.1, `rtx-panel.lua` v3.7.0, `smooth.lua` v2.4.1, `binaural.lua` v1.7.0,
`eq.lua` v1.0.0 (replaces `kz-eq.lua`), `peak.lua` v1.7.0. A load audit of the player pipeline (no change to sound or
picture), release defaults, and the headphone EQ as your own profile.
### Changed
- Headphone EQ: `kz-eq.lua` becomes `eq.lua`, a loader for your own AutoEQ profile (ParametricEQ or GraphicEQ
  files in `script-opts/eq/`); the card's EQ row lists them. No profile ships and the EQ is off by default. Options
  `kz_eq-*` are now `eq-*` (1.2.0 was never published, so no released config changes).
- The video filter chain is built once per file; a peak change re-tags only the luma tag, so RTX HDR is not
  re-initialised. Implausible peaks (mpv's 10000 placeholder, or above `peak_max`) are ignored.
- The audio chain is built once, before the audio output opens (one output init per file instead of two); the
  headphone device is remembered between files. Output verified bit-identical before and after.
- State shared with the panel is published only when it changes; detailed log listening is narrowed.
- One reader of the dropped-frame counters (`smooth.lua` publishes them; the VSR stutter guard uses that).
- No live peak meter on a path whose measurement is already complete.
### Fixed
- "Measure now" while a measurement is already running no longer restarts it; it shows the progress.
- The VSR stutter guard and the smooth watchdog ignore drops for 3 s after any transition (start, seek, chain change, fullscreen, resize, audio re-init, display mode change); only steady-state stutter counts.
- The card no longer opens on any mouse movement near the top right: only over the small status box or at the right edge (option `edge_px`, default 4 px); it closes shortly after the pointer leaves it.
### Added
- `peak` option `store_dir=root` with `roots=<folder;folder>`: one hidden `.mpv-measure` index per media root, keyed by file content, so measurements follow files when they move or are renamed. Default unchanged.
- Card: **Make default** / **Reset default** on the Preset row.
- Release defaults: picture and sound as made; crop, RTX HDR, smoothing and EQ off; VSR only on an NVIDIA RTX GPU; peak guard on. See README "Defaults and why".
- `rtx-panel` option `immersive_show` (fill | half | fit, default fill): the Show mode the Immersive preset sets.

## [1.2.0] - 2026-11-24
Scripts: `aspect-rtx.lua` v4.5.2, `rtx-panel.lua` v3.3.0, `smooth.lua` v2.3.1, new `binaural.lua` v1.6.1,
`kz-eq.lua`, `peak.lua` v1.4.0.
### Added
- Audio: `binaural.lua` (3D audio: surround on calibrated virtual speakers through the SADIE II HRTF; 3D stereo: stereo
  on two virtual front speakers), gated to the headphone devices you list. The HRTF file is linked, not included.
- Audio: `kz-eq.lua` headphone EQ, with a KZ ZSN Pro example and options `graphic_eq` / `preamp` for any AutoEQ
  GraphicEQ result.
- Audio: `peak.lua` clip guard: one static negative trim per file to stay under -1 dBTP (no limiter, no compression);
  measured per file and path; **Measure folder** on the card and `peak-analyze=<folder>` measure ahead; `store_dir`,
  `lookahead`.
- Audio: measurement pass (`peak-auto_measure`, default on): an unmeasured file is measured in a fast background
  pass while it plays; the measured trim is applied when done (0.2 s ramp). `Alt+P` / card **Measure now** on demand.
- Audio: pre-roll (`peak-preroll_max`, default off): a short unmeasured file holds its start until measured, like a
  stream buffering; scripts share start holds through `user-data/start_hold/<script>`.
- Crop Auto now detects black bars burned into the picture (one-shot per file); new row **Show as** (Fit | Half | Fill).
- VSR: `vsr_min_scale` (1.3: no VSR below it, "scale too small") and a stutter guard (VSR off for the file after 10
  dropped + delayed frames in 4 s, "VSR off: stutter").
- RTX HDR mode Off | Fullscreen | Always (`hdr_mode`).
- Card along the signal chain (Preset > Source > Video > Audio), compact view with More / Less, presets Faithful |
  Immersive | Custom (`rtx_panel-preset`), a status line for background work and applied marks.
- README: what it is for, the pipeline each feature needs, what breaks a feature, Faithful vs Immersive, why it
  sounds different.
### Changed
- Option `crop` replaces `bars` / `start` (old names still read); sample `mpv.conf` uses `crop=auto`, sets `volume=100`.
### Fixed
- 3D audio without the HRTF file stays off with the reason "no HRTF file" instead of failing the audio filter chain.

## [1.1.0] - 2026-11-23
Scripts: `aspect-rtx.lua` v4.0.3, `rtx-panel.lua` v2.3.1, `smooth.lua` v2.3.1.
### Added
- Selector card (`scripts/rtx-panel.lua`): one row per setting, every option its own badge (Crop: Off / Auto /
  each preset; VSR and RTX HDR: Off / On; Interpolation: Auto / On / Off), one click picks it; chosen-but-waiting options
  are outlined with the reason; Pin and Info badges. The card shows when the pointer comes to the top-right corner
  and hides 0.4 s after it leaves (option `leave_grace`).
- Script-messages for direct choices: `aspect_rtx` `set-crop`, `set-vsr`, `set-hdr` and `smooth` `set-mode`. Keys and
  the filter chain logic are unchanged.
- Crop mode Auto (aspect-rtx, `start=auto` or the card's Auto badge): crops to the display's ratio, only when the
  picture ratio differs from it by more than `ratio_tol` (2 %), so 16:9 video on a 16:9 display is left as is; the
  card says "fits the display". Optional `clamp`. A preset (the `start` one or one you pick) always crops to its
  exact ratio, as before.
- Clean start (aspect-rtx): start hold (playback starts paused and resumes once the chain is live, so the first frame
  is filtered and audio starts with it) and a pre-build of the RTX chain before the decoder starts, from ffprobe, the
  track list and the last known display. New options `prebuild` (ffprobe path; default `ffprobe` from `PATH`, `""` =
  off) and `display_store`. Measured against 1.0.0 (n=10): first play unchanged (2.03 s), worst A/V sync 16 ms vs
  62 ms.
- HDR detection from mpv's own read of the display mode (with the render target as fallback); the RTX HDR row shows
  the detected mode. The scripts run no external program except the optional ffprobe and change no Windows setting.
- `icc_sdr` = `auto` (default) | `yes` | `no`.
- smooth v2.3: `auto` also stays off above `heavy_mpxs` (default 250 Mpx/s decoded) and turns itself off for the
  rest of the file when dropped + delayed frames reach `drop_limit` (4) within `drop_window` (10 s), after a `grace`
  (3 s) following start or seek. New options `heavy_mpxs`, `heavy_bits`, `drop_limit`, `drop_window`, `grace`.
- `script-opts/aspect_rtx.conf`: example option file (`prebuild=ffprobe`).
### Changed
- The panel no longer cycles crop presets on click (and right-click no longer turns crop off); `Alt+a` still cycles.
- rtx-panel: the "Smooth" row is renamed "Interpolation"; the smooth OSD says "Interpolation". Behaviour unchanged.
### Fixed
- Rotated video (aspect-rtx): files with a 90 / 270 degree rotation tag (e.g. phone clips) are cropped and upscaled
  on the picture as it is shown; before, the crop cut the wrong axis and the VSR scale was computed for the unrotated
  frame. The `start` crop skips portrait pictures (card: "portrait picture"); a preset you pick still applies.
- ICC only on an SDR display (aspect-rtx): with Windows HDR on, `icc-profile-auto=yes` made mpv encode its HDR
  output to the ICC profile's 80-nit SDR target (HDR video looked like SDR, SDR video was squeezed into 80 nits).
  `icc-profile-auto` is now off whenever Windows HDR is on, as well as while RTX HDR runs.
- Start of a file: the first frames no longer play unfiltered before the chain is up, and the A/V jump of the late
  rebuild is gone (see clean start above).
- VSR / RTX HDR are applied only on an NVIDIA RTX video device. On another GPU `d3d11vpp` cannot enable RTX VSR
  ("Failed to enable NVIDIA RTX Super Resolution") and scales with that GPU's own video processor; the panel now shows
  "no RTX GPU" instead of claiming VSR is on.
- The start hold no longer resumes a player the user paused during it; smooth's drop guard re-arms after a
  fullscreen toggle or filter change; ffprobe is run by absolute path only (never from the current folder).

## [1.0.0] - 2026-11-21
### Added
- `scripts/aspect-rtx.lua` (script v3.2.5): live aspect crop in front of RTX VSR and RTX Video HDR via `d3d11vpp`;
  scale from display and cropped size; RTX HDR only for SDR sources with Windows HDR on; live display-peak tag with
  stored last value; `icc-profile-auto` off only while RTX HDR runs; fullscreen-only option; chain self-repair.
- `scripts/rtx-panel.lua` (v1.1a): on-screen buttons Crop / VSR / RTX HDR / Smooth / Info with reasons when a
  feature is not available.
- `scripts/smooth.lua` (v2.1): frame blending, `auto` only on uneven cadence.
- `mpv.conf`, `input.conf`: tested sample config (`d3d11-adapter=NVIDIA` for dual-GPU laptops).
- README with requirements, conditions, considerations, troubleshooting, roadmap and credits (Andarwinux's answer in mpv
  discussion #14804, AutoVSR by azumukupoe, forks by natyusha and anthonybaldwin; the latter is the direct base of
  aspect-rtx.lua).
### Changed
- The original `mpv-dynamic-scaling.lua` and its `mpv.conf` moved to `legacy/` unchanged; `aspect-rtx.lua` replaces
  them.

## [0.1.0] - 2025-02-08
- First version: `mpv-dynamic-scaling.lua` (now in `legacy/`).
