# Changelog

All notable changes to mac-toolkit. The format is [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-26

### Added

- One menu bar icon, no Dock icon, with three utilities.
- **Keep Awake**: runs `/usr/bin/caffeinate` with the chosen assertion flags
  and duration, restarts it when they change, ends it with the app, and keeps
  the flags and duration between launches.
- **Keep Media Loud**: writes the value macOS leaves when nothing is ducking
  into the default output device's private `duck` property every 500 ms, so
  media stays at the volume it was set to while a call ducks it.
- **Natural Scrolling**: an event tap that reverses a wheel mouse's discrete
  scroll events and leaves the trackpad's continuous ones with the direction
  System Settings chose.
- `nix build` gives `result/Applications/mac-toolkit.app`; `zig build app` gives
  `zig-out/mac-toolkit.app`; `tools/package.sh` builds and notarizes the
  release archives.

[Unreleased]: https://github.com/jeiang/mac-toolkit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jeiang/mac-toolkit/releases/tag/v0.1.0
