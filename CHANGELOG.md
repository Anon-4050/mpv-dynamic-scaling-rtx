# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/)
(major = breaking config or key changes, minor = new features, patch = fixes). Each release has a git tag `vX.Y.Z`.

## [Unreleased]
- Planned for 1.1.0: Intel GPU pipeline; menu / badge panel that shows all options at once; optional automatic bar
  detection if it passes testing (see README, Roadmap).

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
