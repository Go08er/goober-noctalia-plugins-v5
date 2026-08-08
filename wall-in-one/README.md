# Wall-in-One

Bar controls, a Control Center shortcut, and a palette template for the
[Wall-in-One](https://github.com/Go08er/wall-in-one) wallpaper manager. All of
the wallpaper logic lives in that standalone GTK4 application; this plugin is a
thin client that drives it over its control socket, so nothing here downloads,
decodes, or renders anything.

## Plugin

Plugin id `goober/wall-in-one`, with four entries:

- `control` — the singleton service. It is the only thing that talks to the
  app, starting the plain `wall-in-one` command when requested, running
  `wall-in-one ctl <verb>`, and republishing the answer on a shared state
  channel that every other entry reads.
- `wall-in-one` — the bar widget. Presentation only.
- `controls` — the panel behind the widget's right click. Open it from
  anywhere with `noctalia msg panel-toggle goober/wall-in-one:controls`.
- `wallpaper` — the Control Center shortcut, so a keybind can change the
  wallpaper without the bar.

### How it talks to the app

The app owns a Unix socket at `$XDG_RUNTIME_DIR/wall-in-one.sock` and speaks
one JSON object per line in each direction — a request is `{"verb": ...,
"argument": ...}` and a reply is `{"ok": ..., "message": ...}`. The plugin does
not implement that protocol. `wall-in-one ctl` is the app's own client for it,
and every plugin control is one asynchronous invocation of a `ctl` verb.

The app being closed is an ordinary state rather than an error. `ctl` exits 3
immediately when nothing is listening, so a poll against a dead socket costs
one failed `connect(2)`. The panel and Control Center shortcut can start or
present the application, and a bar gesture made while it is closed starts it
and retries that one gesture once. The long-lived application uses Noctalia's
detached subprocess call; captured `ctl` invocations remain serialized and
carry an 8-second host callback timeout. Startup readiness polling runs at
250 ms for at most 10 seconds and never becomes the resting poll rate.

## Requirements

- `wall-in-one` — the application itself
  ([Go08er/wall-in-one](https://github.com/Go08er/wall-in-one)), on `PATH`.
  This plugin does nothing without it: every entry here is a client of that
  app's control socket.
- Noctalia 5 with plugin API 17 or newer.

Install the app first. It is a Nix flake:

```console
$ nix profile install github:Go08er/wall-in-one
```

Its own README covers `nix run`, using it as a flake input, and what the
package brings with it (mpvpaper and ffmpeg). If the binary ends up somewhere
that is not on `PATH` — a checkout's `result/bin/wall-in-one`, say — set the
**Executable** path in this plugin's settings instead of putting it on `PATH`.

## Usage

Place the **Wall-in-One** widget on a bar. It shows what is on screen now, or
`Not running` when the app is closed. Use **Open Wall-in-One** in the panel or
the Control Center shortcut to launch it. A wallpaper gesture from the stopped
widget also launches the application and replays that one action after its
socket becomes ready.

| gesture | action |
|---|---|
| left click | next wallpaper |
| middle click | random wallpaper |
| right click | open the controls panel |
| back button | previous wallpaper |
| forward button | pause or resume video wallpapers |
| wheel up / down | previous / next wallpaper |

Every one of those is a Noctalia action default and can be remapped per
placement in the widget editor.

The controls panel can open/present the application and holds the settings that
persist: shuffle order, automatic cycling, the cycle interval in seconds, the
dynamics pause, and a palette reload. State-changing controls remain disabled
until the application's socket is ready.

The Control Center shortcut opens the application when it is stopped. Once it
is running, a left click advances the wallpaper and a right click picks a
random one, which is what a compositor keybind ends up driving.

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
- **Running / paused / not-running glyph** — the icon for each state.
- **Running / paused / not-running color** — the colour for each state.

The paused state is what you see when video wallpapers are paused and their
paired stills are showing instead.
