# Wall-in-One

> [!WARNING]
> **Pre-alpha — in testing.** Automated checks cover the control contract,
> but desktop compatibility and settings may still change. It also
> requires the [Wall-in-One](https://github.com/Go08er/wall-in-one) app, which
> is itself pre-alpha — this plugin is only ever as ready as that is.

An intentionally small bar menu for the
[Wall-in-One](https://github.com/Go08er/wall-in-one) wallpaper manager. All of
the wallpaper logic lives in that standalone GTK4 application; this plugin is a
thin client that drives it through `wall-in-one ctl`, which routes commands to
the app's two local sockets. Nothing here downloads, decodes, or renders
anything.

## Plugin

Plugin id `goober/wall-in-one`, with three entries:

- `control` — the singleton service. It is the only thing that talks to the
  app, preferring the packaged `wall-in-one.service` systemd user unit and
  preparing and validating a direct runtime when the unit is absent, running
  `wall-in-one ctl <verb>`, and republishing each atomic runtime snapshot on a
  shared state channel that every other entry reads.
- `wall-in-one` — the bar widget. Presentation only; clicks open its menu.
- `controls` — the runtime control, playlist, schedule, and display menu. Open it from
  anywhere with `noctalia msg panel-toggle goober/wall-in-one:controls`.

The plugin deliberately chooses the **minimal** side of “minimal or fully
configurable.” It does not hide playback commands behind middle-click, wheel,
or mouse-button gestures, and it does not duplicate the application's cycle,
pairing, or schedule editors. The bar menu keeps only the common decisions
that make sense there: choose the active playlist, resume calendar control,
play/pause/stop or move through the playlist, control cycle and shuffle modes,
inspect display assignments, or open the full application. Display assignment
and schedule-rule editing remain configuration work in the app.

The default left and right click actions open the menu. Use the menu's labelled
controls to change playback, playlists, or rotation modes.

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
owns its lifetime. When the unit is absent, the plugin runs
`wall-in-one --service-startup-prepare` and `wall-in-one-service --check-config`
before starting `wall-in-one-service --wait-for-config` directly. A failed,
masked, or still-starting unit is reported; it does not trigger a competing
detached process. The older Python
`wall-in-one --service` compatibility process cannot provide the atomic
inventory and is no longer launched by this plugin. The window is only
configuration: launching plain `wall-in-one` later attaches to the existing
application instance, and closing it leaves the Rust service running.

`ctl` exits 3 immediately when nothing is listening, so a readiness probe
against a dead socket costs one failed `connect(2)`. Captured calls remain
serialized and carry a 55-second callback timeout. This covers the app's
45-second synchronous runtime-action bound (including a three-display helper
handover) while staying below Noctalia's 60-second callback clamp. Startup
readiness polling runs at 250 ms for at most 60 seconds and never becomes the
resting poll rate.

Status snapshots must use the app's status schema version 2. A visible
session-only crash/quarantine report triggers one serialized
`--sync-runtime-health` hand-off. This is redundant but safe with the packaged
systemd timer, and provides durable quarantine for the direct-runtime fallback.

## Requirements

- `wall-in-one` — the application itself
  ([Go08er/wall-in-one](https://github.com/Go08er/wall-in-one)), on `PATH`.
  Its package must include both `wall-in-one` and `wall-in-one-service`; this
  plugin needs the GTK command for configuration and the Rust command for
  runtime control.
  It requires status schema 2, the `--service-startup-prepare` and
  `--sync-runtime-health` commands, and matching executables from the same
  package. Earlier status-schema-1 app builds are incompatible; follow the app's
  [migration guide](https://github.com/Go08er/wall-in-one/blob/main/docs/migrating.md)
  before enabling this companion.
- Noctalia 5 with plugin API 17 or newer.

Companion **v0.1.2** is paired with application **v0.1.3**. That app's
`flake.lock` selects the committed companion containing these startup and
battery-display changes. Install the app first, complete its normal restart,
then enable the matching companion; see the app's
[update guide](https://github.com/Go08er/wall-in-one/blob/v0.1.3/docs/updating.md).

Application v0.1.2 provides the base startup/health commands but lacks battery
support and the newer configuration-recovery fixes. Battery control requires
a running Rust service that accepts runtime configuration schema 5; schema 4
remains supported without the battery option. Status schema 2 alone does not
prove battery support.

When `systemctl` is available, the plugin uses it to prefer the app's packaged
user unit. It is optional when no user unit is installed. A missing unit or an
explicit executable override uses the same migration/validation preflight
before starting a detached runtime. Startup errors appear in the menu; use
**Open Wall-in-One** to complete configuration if no library is selected.

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

When the app's **Stop animations on battery** option is enabled, the menu and
widget tooltip show the resulting restriction separately from playback and
renderer errors. It does not change your chosen playlist, manual playback
state, or schedule. If power status becomes unavailable while the restriction
is held, the companion says so instead of claiming that AC power has returned.

Displays show both their configured assignment and, when an override is in
force, the playlist actually playing. Assignment is read-only here; **Edit
display assignments** opens display assignments in the app's **Schedules**
tab. **Edit schedules** runs
`wall-in-one ctl open schedules`, landing directly on the full schedule editor.
To inspect a pairing's still image, motion and colours, open its item in the
app's **Library** tab.

### Colour sync

The app installs the Noctalia user template that renders its live 72-token
palette. The Luau host API can read configuration but not write it, so the
template and its registration both belong to the app:

```
wall-in-one --install-theme-template
noctalia msg templates-apply
```

That writes a `[theme.templates.user.wall-in-one]` block into Noctalia's
`settings.toml` and points it at the app's installed template. Palette updates
are event-driven: after rendering, Noctalia runs the block's `post_hook` to
reload the app's colours; the app also watches the rendered file.

Registration and output checks cannot prove that a palette change within the
same light/dark mode rendered successfully. If colours stop matching, inspect
the template status and resolved palette, then reapply templates:

```
wall-in-one --theme-status
wall-in-one --print-palette
noctalia msg templates-apply
```

See the app's [colour-sync states](https://github.com/Go08er/wall-in-one#colour-sync)
for the live template, generated approximation and fallback distinction.
To remove the template registration:

```
wall-in-one --uninstall-theme-template
```

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
