# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/)
(major = breaking config or key changes, minor = new features, patch = fixes). Each release has a git tag `vX.Y.Z`.

## [Unreleased]
- Planned: Intel GPU pipeline; optional automatic bar detection if it passes testing.

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
