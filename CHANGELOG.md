# Changelog

All notable changes to mac-toolkit. The format is [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-26

### Fixed

- **Keep Media Loud** no longer writes the `duck` property. Writing it silences
  every app on macOS 27, whatever goes into it — `[1,0,0,0]` as other
  un-ducking tools do, and sixteen zeros as this one did, both during and
  outside a call. The switch now sets the `'nodk'` exemption on the default
  output device instead, and ramps the level back up once per device with
  `AudioDeviceDuck`.
- Clearing the exemption now happens on every pass of a launch that starts with
  the switch off, so an exemption left behind by a crash is removed. A failed
  clear shows in the tooltip as `exemption stuck`.

### Changed

- **Natural Scrolling** taps `kCGSessionEventTap` instead of the HID level: the
  session is where the deltas are what apps will scroll by, with macOS's own
  directional stage already applied. The HID event under the event is reversed
  too, because Chromium scrolls from it.
- **Natural Scrolling** asks for its Accessibility grant when the app starts,
  rather than on the next click of a switch that is already on.

## [0.1.0] - 2026-11-26

### Added

- One menu bar icon, no Dock icon, with three utilities.
- **Keep Awake**: runs `/usr/bin/caffeinate` with the chosen assertion flags
  and duration, restarts it when they change, ends it with the app, and keeps
  the flags and duration between launches.
- **Keep Media Loud**: holds media loud through a call's ducking.
- **Natural Scrolling**: an event tap that reverses a wheel mouse's discrete
  scroll events and leaves the trackpad's continuous ones with the direction
  System Settings chose.
- `nix build` gives `result/Applications/mac-toolkit.app`; `zig build app` gives
  `zig-out/mac-toolkit.app`; `tools/package.sh` builds and notarizes the
  release archives.

[Unreleased]: https://github.com/jeiang/mac-toolkit/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/jeiang/mac-toolkit/releases/tag/v0.1.1
[0.1.0]: https://github.com/jeiang/mac-toolkit/releases/tag/v0.1.0
