# Goober Noctalia v5 Plugins

Standalone Git plugin source for public testing against the native Noctalia v5
runtime. Noctalia can import it directly from
<https://github.com/Go08er/goober-noctalia-plugins-v5>. This tree is
intentionally separate from the Quickshell-based v4.7 repository.

The v5 plugin API is currently beta. Manifests and runtime APIs can still
change before Noctalia v5 is stable, so this source should be treated as a
beta test source rather than a stable plugin feed. It is not included in
Noctalia's built-in official or community catalogs; add it as a custom Git
source using one of the methods below.

## Available plugins

| Plugin | Version | Status |
| --- | --- | --- |
| `goober/hydra-update-examiner` | `0.4.0` | Beta.7/API 15, streamlined v5 settings |
| `goober/nocvox` | `0.3.0` | Beta.7/API 17 focused control companion |
| `goober/wall-in-one` | `0.2.0` | Beta.7/API 17 coordination preview |

## Repository layout

```text
catalog.toml
hydra-update-examiner/
  plugin.toml
  README.md
  thumbnail.webp
  panel.luau
  service.luau
  widget.luau
  translations/en.json
  scripts/hydra-channel-progress
nocvox/
  plugin.toml
  README.md
  thumbnail.webp
  service.luau
  panel.luau
  widget.luau
  translations/en.json
wall-in-one/
  plugin.toml
  README.md
  thumbnail.webp
  service.luau
  panel.luau
  widget.luau
  shortcut.luau
  translations/en.json
  scripts/capture-still
tools/validate.py
flake.nix
flake.lock
tests/vm/
```

Noctalia v5 discovers Git sources through `catalog.toml`. Each plugin lives in
a root directory matching the plugin part of its `author/plugin` id. Hydra
targets API 15. The two service-backed MVPs target API 17 so enabling them on
beta.7 starts their singleton services immediately and exposes lifecycle
reasons. The pinned v5.0.0-beta.7 host accepts cumulative plugin API levels
through 20.

## Install from GitHub

Repository URL:

```text
https://github.com/Go08er/goober-noctalia-plugins-v5
```

Plugin IDs:

```text
goober/hydra-update-examiner
goober/nocvox
goober/wall-in-one
```

### Settings interface

1. Open **Settings**, select **Plugins**, and add a plugin source.
2. Choose **Git**, use `goober-v5` as the source name, and enter the repository
   URL above.
3. Enable whichever plugins you want after the source finishes loading.
4. Add their widgets from the bar picker. Wall-in-One also exposes an
   optional Control Center shortcut.

The source name is only a local handle. `goober-v5` is used throughout this
README so the CLI and configuration examples agree.

### Command line

```bash
noctalia msg plugins source add goober-v5 git https://github.com/Go08er/goober-noctalia-plugins-v5
noctalia msg plugins enable goober/hydra-update-examiner
noctalia msg plugins enable goober/nocvox
noctalia msg plugins enable goober/wall-in-one
noctalia msg plugins list
```

The available bar entries are `goober/hydra-update-examiner:hydra`,
`goober/nocvox:nocvox`, and
`goober/wall-in-one:wall-in-one`. The Wall-in-One Control Center entry is
`goober/wall-in-one:wall-in-one-shortcut`. The source is cloned and
managed by Noctalia; a separate manual checkout is not required.

### Declarative configuration

Add the source and plugin ID to the v5 configuration:

```toml
[plugins]
enabled = [
  "goober/hydra-update-examiner",
  "goober/nocvox",
  "goober/wall-in-one",
]
auto_update = true

[[plugins.source]]
name = "goober-v5"
kind = "git"
location = "https://github.com/Go08er/goober-noctalia-plugins-v5"
enabled = true

[widget.hydra-readiness]
type = "goober/hydra-update-examiner:hydra"
display_mode = "on_hover"

[widget.nocvox]
type = "goober/nocvox:nocvox"

[widget.wall_in_one]
type = "goober/wall-in-one:wall-in-one"

[plugin_settings."goober/hydra-update-examiner"]
refresh_interval_minutes = 60
```

Add the desired widget keys to a bar section using the rest of your normal bar
configuration. Place the Wall-in-One shortcut through Noctalia's Control Center
editor. When declaring `[[plugins.source]]` entries yourself, retain any other
plugin sources you still want configured.

## Updating or removing the source

Use the refresh control beside `goober-v5` in **Settings** → **Plugins**, or
request a background update from the CLI:

```bash
noctalia msg plugins update goober-v5
```

With `plugins.auto_update = true`, Noctalia also refreshes enabled Git sources
automatically. To uninstall the plugin and remove this custom source:

```bash
noctalia msg plugins disable goober/hydra-update-examiner
noctalia msg plugins disable goober/nocvox
noctalia msg plugins disable goober/wall-in-one
noctalia msg plugins source remove goober-v5
```

Removing a source through Noctalia also removes its managed checkout. It does
not delete an independently cloned development checkout.

## Local development

Contributors can clone the repository and point a Noctalia v5 path source at
the repository root. Do not point it at a workspace parent or directly at the
plugin subdirectory. Replace the example path with the checkout's absolute
path:

```bash
noctalia msg plugins source add goober-v5-dev path /absolute/path/to/goober-noctalia-plugins-v5
noctalia msg plugins enable goober/hydra-update-examiner
noctalia msg plugins enable goober/nocvox
noctalia msg plugins enable goober/wall-in-one
```

Then add the desired entries from Noctalia's widget and Control Center editors.
Luau file edits hot-reload. Manifest edits are picked up on the next Noctalia
configuration reload. If the Git and path sources are both present, source
ordering determines which copy supplies a duplicate plugin ID; remove or
disable the Git source while developing if you want to avoid that ambiguity.

### NocVox boundary

NocVox listens to one extended `voxtype status --follow` stream and
forwards only supported recording start, stop, cancel, and on-demand diagnostic
commands. It never installs, starts, stops, updates, configures, or supervises
the VoxType daemon. The default bar actions are left-click toggle, right-click
details, and Noctalia's normal middle-click widget settings. Start, stop, and
cancel use VoxType's configured defaults; NocVox has no per-recording override
or notification subsystem. The plugin does not read the clipboard or persist transcripts; see
[`nocvox/README.md`](nocvox/README.md) for the full ownership and privacy
boundary.

### Wall-in-One coordination and pairing

Wall-in-One provides one configurable bar and Control Center entry point for
Noctalia's native wallpaper controls and compatible live/background plugins.
It discovers enabled plugins through Noctalia's public plugin list and routes
only their documented interfaces: the Wallhaven browser, W Engine's panel and
`next`/`cycle-stop`/`stop` service messages, and mpvpaper's picker plus
`pause`/`resume`/`toggle`/`clear` service messages. An advanced full panel ID
can expose another provider as an open-only adapter. Each provider keeps
ownership of its renderer, files, and scheduling.

For a configured video, Wall-in-One exports a full-resolution frame with FFmpeg
into the selected capture directory. A configured W Engine Workshop ID can use
the same path for video projects; scene and web projects safely export the
Workshop preview. Current upstream W Engine has no public status or capture API,
so Wall-in-One neither guesses its current project from process arguments nor
starts a competing renderer. A versioned cooperative handshake is ready for a
future W Engine adapter to report the active ID and return a same-process
rendered capture.

**Capture and pair** applies the exported still with Noctalia's
`setWallpaper(output, path)` runtime API. The dynamic provider keeps rendering,
while Noctalia persists a real static wallpaper for color generation, backdrop
and blur consumers, wallpaper hooks, and a lock screen configured to follow the
wallpaper. A lock screen with its own explicit image continues to use that
image; Wall-in-One does not overwrite that setting.

Noctalia has one global palette, not one palette per output. With color sync
enabled, Wall-in-One selects the configured wallpaper color scheme; on a
multi-output setup, **Palette output** chooses which paired still is reapplied
last as the deterministic palette leader. Without a leader, the last paired
output wins. Disabling Wall-in-One's color-sync command does not freeze an
existing wallpaper-sourced palette: applying a new wallpaper may still cause
Noctalia itself to regenerate colors.

Open the hub directly with
`noctalia msg panel-toggle goober/wall-in-one:hub`, then assign **Open
Wall-in-One** to a gesture if you want a permanent UI route. The Wall-in-One
bar glyph and NocVox's idle, active, stopped, and unknown-state glyphs use
Noctalia's native per-placement searchable selector. Coordinated mixed-provider
rotation is still refinement work; Wall-in-One does not start a competing
timer yet. See [`wall-in-one/README.md`](wall-in-one/README.md) for current
requirements and safety boundaries.

### Hydra Update Examiner customization

The plugin gear exposes only the singleton poller's channel, interval, and
readiness-threshold controls. Middle-click a placed widget to edit that
placement's text mode, colors, glyphs, and native Actions bindings together.
The glyph fields use Noctalia's searchable picker. Left-click refresh and
right-click panel defaults are ordinary native actions, so they are visible and
replaceable in the same widget editor; middle-click keeps the shell's standard
settings route.

V0.4.0 removes the temporary shared/local appearance duplication from v0.2 and
v0.3. Existing widget-local display, color, and glyph values remain applicable;
obsolete `shared_*` and `use_shared_*` keys can be removed from handwritten
configuration.

Run the repository checks with:

```bash
python3 tools/validate.py
noctalia plugins lint hydra-update-examiner nocvox wall-in-one
python3 nocvox/tests/check.py
python3 wall-in-one/tests/test_contract.py
```

Run the native v5 integration test in a disposable NixOS VM with:

```bash
nix build -L .#vm-test
nix build -L .#vm-test-nocvox
nix build -L .#vm-test-wall-in-one
```

The VM harnesses are pinned to the exact beta.7 host revision. They use
in-guest sources, headless Sway, software rendering, and deterministic command
fixtures without touching the host Noctalia session or configuration. The
original `vm-test` retains Hydra's render and glyph-picker coverage; the two
isolated checks exercise the companion/coordinator services, failure
boundaries, capture/pairing policy, and process-ownership rules. See
`tests/vm/README.md` for details.

## Editor setup

The included `.luaurc` matches Noctalia's nonstrict plugin runtime. For host API
autocomplete and typo diagnostics, configure `luau-lsp` to use the current
[`noctalia.d.luau`](https://github.com/noctalia-dev/official-plugins/blob/main/noctalia.d.luau)
from the official plugin repository as a definition file. It is intentionally
not vendored here while the beta API is changing quickly.

## Publication status

This repository is a directly importable custom Git source for native v5
testing. Hydra Update Examiner and NocVox are ready for direct testing here; the
next Wall-in-One revision remains local staging work until its own publication
step. None of the plugins has been submitted to, accepted into, or registered
with Noctalia's built-in official or community catalogs. See `PORTING.md` and
each plugin README for migration decisions and remaining work.

## License

MIT. See `LICENSE`.
