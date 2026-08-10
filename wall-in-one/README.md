# Wall-in-One

> [!WARNING]
> **Pre-alpha — in testing.** The plugin loads and its entries work, but it has
> had almost no real use. Expect bugs and expect settings to move. It also
> requires the [Wall-in-One](https://github.com/Go08er/wall-in-one) app, which
> is itself pre-alpha — this plugin is only ever as ready as that is.

An intentionally small bar menu and a palette template for the
[Wall-in-One](https://github.com/Go08er/wall-in-one) wallpaper manager. All of
the wallpaper logic lives in that standalone GTK4 application; this plugin is a
thin client that drives it over its control socket, so nothing here downloads,
decodes, or renders anything.

## Plugin

Plugin id `goober/wall-in-one`, with three entries:

- `control` — the singleton service. It is the only thing that talks to the
  app, preferring the packaged `wall-in-one.service` systemd user unit and
  falling back to `wall-in-one-service --wait-for-config`, running
  `wall-in-one ctl <verb>`, and republishing each atomic runtime snapshot on a
  shared state channel that every other entry reads.
- `wall-in-one` — the bar widget. Presentation only; clicks open its menu.
- `controls` — the playlist, schedule, and display menu. Open it from
  anywhere with `noctalia msg panel-toggle goober/wall-in-one:controls`.

The plugin deliberately chooses the **minimal** side of “minimal or fully
configurable.” It does not hide playback commands behind middle-click, wheel,
or mouse-button gestures, and it does not duplicate the application's cycle,
pairing, or schedule editors. The bar menu keeps only the common decisions
that make sense there: choose the active playlist, resume calendar control,
play/pause/stop or move through the playlist, control cycle and shuffle modes, inspect display
assignments, or open the full application. Display assignment and schedule-rule
editing remain configuration work in the app.

Widget click actions are intentionally fixed in this minimal design. A later
configurability pass may expose those two menu-opening gestures, but it should
not reintroduce hidden wallpaper-changing clicks or wheel actions.

### How it talks to the app

There are deliberately two sockets. The always-on Rust service owns
`$XDG_RUNTIME_DIR/wall-in-one-runtime.sock`; runtime commands and its atomic
JSON `status` snapshot live there. The GTK authoring app owns
`$XDG_RUNTIME_DIR/wall-in-one.sock` while its window process is running. The
plugin does not implement either line protocol: `wall-in-one ctl` routes each
verb to its owner, and every plugin action is one asynchronous `ctl` invocation.

One runtime `status` reply carries playback state plus the complete playlist,
schedule, and display-assignment inventory. The menu never calls nonexistent
runtime `playlists`, `schedule`, or `displays` listing verbs and does not need
the GTK app to be running. Display assignments are read-only in the bar because
they are configuration, not runtime state.

The plugin starts the service when its singleton entry loads. If the packaged
systemd user unit is available, `systemctl --user start wall-in-one.service`
owns its lifetime; otherwise the plugin starts
`wall-in-one-service --wait-for-config` directly. The older Python
`wall-in-one --service` compatibility process cannot provide the atomic
inventory and is no longer launched by this plugin. The window is only
configuration: launching plain `wall-in-one` later attaches to the existing
application instance, and closing it leaves the Rust service running.

`ctl` exits 3 immediately when nothing is listening, so a readiness probe
against a dead socket costs one failed `connect(2)`. Captured calls remain
serialized and carry an 8-second callback timeout. Startup readiness polling
runs at 250 ms for at most 10 seconds and never becomes the resting poll rate.

## Requirements

- `wall-in-one` — the application itself
  ([Go08er/wall-in-one](https://github.com/Go08er/wall-in-one)), on `PATH`.
  Its package must include both `wall-in-one` and `wall-in-one-service`; this
  plugin needs the GTK command for configuration and the Rust command for
  runtime control.
- Noctalia 5 with plugin API 17 or newer.

When `systemctl` is available, the plugin uses it to prefer the app's packaged
user unit. It is optional: a failed or unavailable unit falls back to a
detached `wall-in-one-service --wait-for-config`.

Install the app first. It is a Nix flake:

```console
$ nix profile install github:Go08er/wall-in-one
```

Its own README covers `nix run`, using it as a flake input, and what the
package brings with it (mpvpaper, ffmpeg, and linux-wallpaperengine). If the
binary ends up somewhere that is not on `PATH` — a checkout's
`result/bin/wall-in-one`, say — set the
**Executable** path in this plugin's settings instead of putting it on `PATH`.

## Usage

Place the **Wall-in-One** widget on a bar. It shows what is on screen now, or
`Starting` while the service comes up. Either primary or secondary click opens
the same compact menu; no other gesture changes wallpaper state.

| gesture | action |
|---|---|
| left click | open the playlist menu |
| right click | open the playlist menu |

The menu lists named playlists with their entry counts and marks every playlist
currently active on a display. Choosing another sends `playlist-use <name>`;
**Follow schedule** sends `schedule-follow`. Playback controls send
`previous`, `toggle`, `next`, `random`, `stop`, `cycle on|off|default`, and
`shuffle on|off` directly to the Rust runtime. Random is a one-shot jump;
shuffle changes the order used by future cycling. Cycle off holds the current
wallpaper without stopping its motion. Pause freezes the resident renderer,
while Stop releases it and leaves the paired still visible until Play resumes
motion. The schedule section shows the calendar target and rule currently
selected, including while a manual override is active.

Displays show both their configured assignment and, when an override is in
force, the playlist actually playing. Assignment is read-only here; **Edit
display assignments** opens the app's Displays page. **Edit schedules** runs
`wall-in-one ctl open schedules`, landing directly on the full schedule editor.

### Colour sync

The plugin ships `palette.json.tmpl`, the Noctalia user template that renders
the live 72-token palette for the app. Shipping it is all the plugin can do —
the Luau host API can read configuration but not write it, so registering the
template is the app's job:

```
wall-in-one --install-theme-template
noctalia msg templates-apply
```

That writes a `[theme.templates.user.wall-in-one]` block into Noctalia's
`settings.toml` and points it at a copy of this template. Noctalia then
re-renders the palette on every change and runs the block's `post_hook`, which
tells the running app to reload its colours. Palette sync is push-based: no
polling and no drift.

To check or undo it:

```
wall-in-one --theme-status
wall-in-one --uninstall-theme-template
```

The copy in this directory is the same file the app installs; it is here so the
template is readable without the app checked out, and so a materialized plugin
directory is self-describing.

## Settings

Plugin settings, owned by the singleton service:

- **Refresh seconds** — how often the service asks the app for its state.
  Default 15, range 5–300. This is the only polling the plugin does.
- **Executable** (advanced) — full path to `wall-in-one`. Empty means use
  `PATH`.

Widget settings, per bar placement:

- **Wallpaper name** — always, on hover, or never.
- **Running / not-running glyph** — the icon for each state.
- **Running / not-running color** — the colour for each state.
