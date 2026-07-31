# Wallpaper Director

Wallpaper Director is a native Noctalia v5 wallpaper hub. Version `0.1.0`
delivers the phase-one routing surface without taking work away from the
providers that already do it well.

## What works now

- A configurable three-button bar widget.
- A Control Center shortcut using its currently supported left and right
  callbacks.
- An attached panel with shortcut mapping, provider availability, phase status,
  and diagnostics.
- Native Noctalia wallpaper selector, next, previous, and random actions.
- Safe delegation to the official Wallhaven browser and W Engine browser.
- Asynchronous provider detection using `noctalia msg plugins list`, plus a
  separate `linux-wallpaperengine` capability check.
- Schema-versioned `config.json` and `runtime.json` in the plugin data
  directory, written via temporary file + rename while retaining `.bak`
  last-known-good files.

First-run bar defaults are:

| Gesture | Destination |
|---|---|
| Left click | Noctalia's static wallpaper selector |
| Middle click | Wallhaven browser |
| Right click | W Engine browser |

Open the Director panel to change each mapping. On a fresh install, the panel is
always reachable with Noctalia's public panel IPC even though all three default
widget gestures are already assigned:

```bash
noctalia msg panel-toggle goober/wallpaper-director:director
```

Optional provider actions are offered as new choices only while their providers
are available. If a provider later disappears, its saved mapping is preserved
as **configured but unavailable**, execution is blocked, and the panel explains
why. Director never silently remaps a gesture. You can assign **Open Wallpaper Director**
to any gesture from that panel for a permanent UI route.

Widget glyph, label visibility, label text, and theme-token color remain native
per-placement settings. Middle click is intentionally unbound from Noctalia's
usual widget-settings default so all three buttons reach the Director mapping.

## Ownership boundary

This release does not launch, stop, signal, or inspect a
`linux-wallpaperengine` process. It does not read or edit W Engine's private
`data.json`, change live scene properties, suppress Noctalia's wallpaper
surface, or alter Noctalia's imperative settings file.

- Noctalia owns static wallpaper rendering, transitions, and the selector.
- W Engine remains the only owner of live Wallpaper Engine processes.
- Wallhaven remains the browser/downloader.
- Director owns only routing and its own small configuration/runtime files.

Native next/previous/random are implemented only through Noctalia's fixed
public IPC commands: `wallpaper-next`, `wallpaper-previous`, and
`wallpaper-random`. They target the invoking widget or focused output when one
can be validated, otherwise Noctalia's default wallpaper scope is used.

## Deliberately staged

The Pairing and Reels sections are honest previews, not inactive controls.
Live-scene capture, native-surface suppression, stop/restore policy, and mixed
reels require both a public W Engine adapter and a proven lifecycle cleanup
path. Until then, Director will not race W Engine, start a second renderer,
rewrite W Engine's storage, or coordinate competing timers.

The Control Center plugin shortcut in Noctalia `5.0.0-beta.7` exposes left and
right click but no middle-click callback. Its left and right clicks use the
corresponding Director mappings; the bar widget provides all three. No scroll
substitution is made.

## Installation

After this plugin is added to a Noctalia v5 catalog source, enable
`goober/wallpaper-director` in Noctalia's Plugins settings. Place the
`goober/wallpaper-director:wallpapers` widget and/or the
`goober/wallpaper-director:wallpapers-shortcut` tile through Noctalia's UI.
Nothing is placed or enabled automatically.

## Validation

```bash
noctalia plugins lint wallpaper-director
python3 wallpaper-director/tests/test_contract.py
```

See [TESTING.md](TESTING.md) for the phase-one manual test record and deferred
acceptance checks.
