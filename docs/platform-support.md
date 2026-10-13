# Platform support

Status legend: **verified** means tested on real hardware by the maintainer.
**Expected** means it should work from how the desktop works, but is untested.
Please file a Platform report issue with your results.

Only GNOME 50 on Wayland, x86_64, is verified.

## Android

Android 12 or newer (API 31), arm64-v8a; Android 16 features are used where available. A keyboard (InputMethodService) with a
Flutter UI: hold-to-talk, processing state, text inserted with `commitText`, and
a switch back to the previous keyboard. GPU acceleration through OpenCL
(Snapdragon and Adreno work).

## Linux matrix

| Desktop, session | Hotkey | Insertion | Overlay | Tray |
|---|---|---|---|---|
| GNOME 50 Wayland x86_64 | verified, GlobalShortcuts portal | verified, RemoteDesktop portal (consent once, token restored) | notification (no layer-shell) | verified with AppIndicator extension |
| GNOME X11 | expected, portal or custom shortcut | expected, xdotool | notification | expected |
| KDE Wayland | expected, portal | expected, RemoteDesktop portal | expected, layer-shell | expected |
| KDE X11 | expected, portal | expected, xdotool | expected | expected |
| Hyprland | expected, portal | expected, wtype | expected, layer-shell | expected |
| Sway | expected, compositor binding | expected, wtype | expected, layer-shell | expected |

Fallback everywhere: ydotool (optional, see below), then clipboard plus a
notification.

Other details:

- Microphone: native PipeWire through `libramble_capture.so` (`pw_stream`), then
  libpulse-simple, then `pw-record`.
- GPU: Vulkan with a real vendor driver. Software Vulkan (llvmpipe) cannot be
  used, so the app falls back to CPU.
- Tray: StatusNotifierItem. GNOME needs the AppIndicator extension.
- Overlay: gtk4-layer-shell on KDE and wlroots compositors. GNOME has no
  layer-shell, so a notification is shown instead.

## Command-line control

A second launch forwards its command to the running instance:

```
ramble_voice --toggle   # start or stop
ramble_voice --start
ramble_voice --stop
ramble_voice --show
ramble_voice --background   # start hidden
```

## Sway (no GlobalShortcuts portal)

`xdg-desktop-portal-wlr` has no GlobalShortcuts, so bind the CLI. Hold-to-talk:

```
# ~/.config/sway/config
bindsym $mod+space exec ramble_voice --start
bindsym --release $mod+space exec ramble_voice --stop
```

Or toggle:

```
bindsym $mod+space exec ramble_voice --toggle
```

For the Flatpak use `flatpak run io.github.luohoa97.RambleVoice --toggle`.

## Hyprland

Preferred: grant the shortcut in the portal dialog. Manual alternative:

```
# ~/.config/hypr/hyprland.conf
bind  = SUPER, space, exec, ramble_voice --start
bindr = SUPER, space, exec, ramble_voice --stop
# or: bind = SUPER, space, exec, ramble_voice --toggle
```

Text insertion uses `wtype`, which needs the compositor to support the virtual
keyboard protocol (Hyprland and Sway do).

## GNOME custom shortcut fallback

If the portal route is unavailable (older than GNOME 48, or X11), add a custom
shortcut: Settings, Keyboard, View and Customize Shortcuts, Custom Shortcuts,
add `ramble_voice --toggle` (Flatpak: `flatpak run
io.github.luohoa97.RambleVoice --toggle`). Custom shortcuts do not report key
release, so use toggle mode, not hold-to-talk.

## Optional ydotool route

`packaging/linux/host-setup.sh` runs on the host, asks for confirmation, then:

1. installs the udev rule `/etc/udev/rules.d/80-ramble-uinput.rules` giving the
   active seat user access to `/dev/uinput`,
2. checks that `ydotoold` is installed (dnf, apt or pacman; on rpm-ostree or
   Bluefin use `brew install ydotool` or `rpm-ostree install ydotool`),
3. creates and enables a systemd user service running
   `ydotoold --socket-path=$XDG_RUNTIME_DIR/.ydotool_socket`.

It is idempotent. `host-setup.sh --uninstall` reverts everything. The Flatpak is
granted `xdg-run/.ydotool_socket` access.

## Autostart

Autostart is optional and off by default. To start hidden at login, add a
desktop entry in `~/.config/autostart/` with `Exec=ramble_voice --background`
(Flatpak: `flatpak run io.github.luohoa97.RambleVoice --background`).
