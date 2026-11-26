<p align="center"><img src="macos/icon.png" alt="mac-toolkit's icon" width="128" height="128"></p>

# mac-toolkit

Three small macOS utilities behind one menu bar icon, in Zig on
[nanoui](https://github.com/justrach/nanoui). No window, no Dock icon.

The icon's menu has:

- **Keep Awake**: starts or stops `/usr/bin/caffeinate`.
  **Keep Awake Options** holds the assertion flags (`-d` display sleep, `-i`
  idle sleep, `-m` disk idle sleep, `-s` system sleep on AC power, `-u` user
  active; with none checked caffeinate prevents idle sleep, as `-i` does, and
  `-d` and `-i` start checked) and the duration (`-t`: indefinitely, or 15
  minutes to 8 hours). A change while caffeinate runs restarts it. caffeinate
  always gets `-w <pid>`, so it ends with the app. The flags and the duration
  are kept between launches; caffeinate starts only from the menu.
- **Keep Media Loud**: holds media at the volume you set while macOS ducks it
  for a call. When a call starts, macOS writes an attenuation into the default
  output device's private `duck` property, and every other app's media drops to
  a whisper; this writes back the value macOS leaves when nothing is ducking,
  every 500 ms, until the call ends.
- **Natural Scrolling**: a mouse wheel scrolls the classic way while the
  trackpad keeps macOS's natural direction, at the same time. It is an event
  tap that reverses discrete wheel events and leaves the trackpad's continuous
  ones alone, so System Settings' one direction still applies to each.

The tooltip says what all three are doing: `awake · media loud · mouse
reversed`, or `asleep · media ducks · mouse needs Accessibility`.

## Permissions

Natural Scrolling needs **Accessibility** (System Settings → Privacy & Security
→ Accessibility): a tap that changes input events is not allowed without it.
Grant it once per build; an unsigned rebuild is a new app to macOS. When the
grant is missing the tap is never created, so nothing is left reversed, and the
menu says so. Keep Awake and Keep Media Loud need no permissions.

## Limits

- A mouse that scrolls smoothly (Apple's Magic Mouse, Logitech's with Logi
  Options) sends pixel-based events, the same as a trackpad, so it keeps the
  trackpad's direction. A wheel mouse's line-based events are what this
  reverses.
- The duck property is private and undocumented. It reads all zeros while
  nothing is ducking on macOS 27; writing `1.0` into its first Float32, as if
  that were a gain, silences every app instead of holding it loud.
- macOS 14.2 or newer, as the duck property is. No microphone access, no
  kernel extension, no virtual audio device.

## Install

Download the zip for your Mac (Apple silicon: `aarch64`, Intel: `x86_64`) from
Releases, unzip it, and move `mac-toolkit.app` to `/Applications`.

With Nix: `nix build`, then `result/Applications/mac-toolkit.app`.

## Build

```sh
nix develop -c zig build run    # from the menu bar, until you quit it
nix develop -c zig build app    # zig-out/mac-toolkit.app
nix develop -c zig build test   # the caffeinate command line, the kept settings,
                                # the duck payload, and a reversed wheel event
nix develop -c zig build icon   # redraws macos/icon.png and macos/AppIcon.icns
nix build                       # result/Applications/mac-toolkit.app
```

## License

MIT, in [`LICENSE`](LICENSE). The app is built on nanoui (MIT); its notices, and
those of the code nanoui takes from others, ship in the bundle under
`Contents/Resources/licenses`.
