# mac-toolkit agent guide

mac-toolkit is a macOS menu bar app in Zig 0.17.1 with three utilities behind
one icon: Keep Awake starts and stops `/usr/bin/caffeinate`, Keep Media Loud
clears the duck attenuation macOS writes into the output device during a call,
and Natural Scrolling reverses a mouse wheel while the trackpad keeps the
system's direction. It draws nothing itself: the menu is
[nanoui](https://github.com/justrach/nanoui)'s tray, pinned in `build.zig.zon`.
macOS is the only target: all three utilities are macOS's.

## Environment

Run every command inside the flake devshell: `nix develop -c <command>`. The
shell hook unsets `NIX_CFLAGS_COMPILE` and `NIX_LDFLAGS`; with them set, Zig
searches only Nix paths. `build.zig` adds the SDK's framework and library paths
itself for the same reason. The `.envrc` loads the shell with nix-direnv.

| Task | Command |
|---|---|
| Unit tests | `zig build test --summary all` |
| Format check | `zig fmt --check build.zig src tools` |
| Run | `zig build run` |
| macOS bundle | `zig build app` (gives `zig-out/mac-toolkit.app`) |
| Release archives | `./tools/package.sh dist` (signs and notarizes with the variables below) |
| Redraw the icon | `zig build icon` (macOS host; writes `macos/icon.png`, `macos/AppIcon.icns`) |
| Nix package and checks | `nix build`, `nix flake check -L` |

A change to `macos/icon.png` or `macos/AppIcon.icns` must be `git add`ed before
`nix build`: flakes read the git tree, and the bundle step installs both.

## Layout

| File | Role |
|---|---|
| `src/main.zig` | Startup: the accessory app, the menu, the run loop |
| `src/menu.zig` | The one tray icon and its menu, and the tick that passes over all three |
| `src/caffeinate.zig` | Flags, durations, the argument vector and the kept settings, with tests |
| `src/keeper.zig` | The caffeinate process: spawn, stop, and reap when it ends on its own |
| `src/duck.zig` | Core Audio's duck property: the address, the payload, and the write |
| `src/scroll.zig` | The event tap: which events are a wheel, and how their deltas reverse |
| `src/timer.zig` | A repeating CFRunLoop timer in every mode, so the tick runs while the menu is open |
| `macos/Info.plist` | The bundle's plist; `LSUIElement` keeps it out of the Dock |
| `tools/icon.zig` | Draws the app icon from signed distances; `sips` and `iconutil` make the `.icns` |

One tick on the main thread does all the work: it reaps caffeinate, repeats the
duck write, and starts the event tap once macOS allows it. Nothing runs during
it that could block, and nothing is written off the main thread, so the Core
Audio calls, the tap and the tray never race.

### The duck property

`duck.zig` writes 16 zero bytes to the output scope of the default output
device's `duck` property, which is what the property reads when nothing is
ducking. The first Float32 is the attenuation macOS adds, not a gain it
multiplies by: writing `1.0` into it silences every app, call or no call. A
probe on macOS 27 found the property on the output scope only (`glob` has
none), 16 bytes, settable, all zeros while idle.

### The event tap

`scroll.zig` taps `kCGHIDEventTap` and reverses only events whose
`kCGScrollWheelEventIsContinuous` is zero: a wheel's line-based events, never a
trackpad's pixel-based ones. macOS recomputes the pixel and fixed-point deltas
from the line delta whenever it is set, so all three are written after it, each
reversed from the value the event arrived with (Scroll Reverser's order). The
HID event under the CGEvent is reversed too, because Chromium scrolls from it;
`CGEventCopyIOHIDEvent` is a Core Graphics SPI.

The tap needs the Accessibility permission. Without it `CGEventTapCreate`
returns null, and the menu's tooltip says so; nothing is left reversed because
no event was ever changed.

## Code rules (Tiger Style)

These apply to `src/`, `tools/` and `build.zig`:

- No allocation in `src/`; buffers are fixed-size fields or on the stack.
  `tools/` may use its arena.
- Every limit is a named constant with the qualifier last (`pass_ms`,
  `tooltip_bytes_max`).
- Every loop has a fixed upper bound. No recursion.
- Assert arguments, results and invariants. Do not add assertions that check
  nothing.
- Explicitly sized integers; `usize` only to index slices.
- Functions at most 70 lines, lines at most 100 columns, `zig fmt` clean.
- `snake_case` for functions and variables; nanoui's camelCase names are
  called as they are.
- Handle every error with a visible state change: the tooltip shows what a
  failed pass found. Comments explain why, not what.

## Nix package

`packages.default` builds with Zig from `zig-overlay` against a fixed-output
derivation of the Zig package tree (`zig build --fetch=all`). When
`build.zig.zon` changes its dependencies, set that derivation's `outputHash` to
`lib.fakeHash`, run `nix build`, and copy the reported hash.

## Licenses

mac-toolkit is MIT (`LICENSE`). `nanoui_notices` in `build.zig` lists the nanoui
files every binary copy carries; check it against nanoui's
`THIRD_PARTY_NOTICES.md` when the pin moves.

## Releases

1. Set `.version` in `build.zig.zon` and `CFBundleShortVersionString` in
   `macos/Info.plist`.
2. Move the `Unreleased` entries in `CHANGELOG.md` to a new
   `## [X.Y.Z] - YYYY-MM-DD` section and update the links at the bottom.
3. Merge to `main`, then tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. Run `./tools/package.sh` with `CODESIGN_IDENTITY` and `NOTARY_KEY_PATH`,
   `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, and attach the zips to a GitHub
   Release whose notes are that changelog section. There is no release
   workflow: the signing secrets are not in this repository.

## Git

Use Conventional Commits. Do not commit `zig-out/`, `.zig-cache/`, `zig-pkg/`,
`dist/` or `result`.
