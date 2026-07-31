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
| `goober/hydra-update-examiner` | `0.3.0` | Beta.7/API 15, VM-validated |
| `goober/voxtype-suite` | `0.1.0` | Beta.7/API 17 companion MVP |
| `goober/wallpaper-director` | `0.1.0` | Beta.7/API 17 Hub MVP |

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
voxtype-suite/
  plugin.toml
  README.md
  thumbnail.webp
  service.luau
  panel.luau
  widget.luau
  translations/en.json
wallpaper-director/
  plugin.toml
  README.md
  thumbnail.webp
  service.luau
  panel.luau
  widget.luau
  shortcut.luau
  translations/en.json
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
goober/voxtype-suite
goober/wallpaper-director
```

### Settings interface

1. Open **Settings**, select **Plugins**, and add a plugin source.
2. Choose **Git**, use `goober-v5` as the source name, and enter the repository
   URL above.
3. Enable whichever plugins you want after the source finishes loading.
4. Add their widgets from the bar picker. Wallpaper Director also exposes an
   optional Control Center shortcut.

The source name is only a local handle. `goober-v5` is used throughout this
README so the CLI and configuration examples agree.

### Command line

```bash
noctalia msg plugins source add goober-v5 git https://github.com/Go08er/goober-noctalia-plugins-v5
noctalia msg plugins enable goober/hydra-update-examiner
noctalia msg plugins enable goober/voxtype-suite
noctalia msg plugins enable goober/wallpaper-director
noctalia msg plugins list
```

The available bar entries are `goober/hydra-update-examiner:hydra`,
`goober/voxtype-suite:voxtype`, and
`goober/wallpaper-director:wallpapers`. The Director Control Center entry is
`goober/wallpaper-director:wallpapers-shortcut`. The source is cloned and
managed by Noctalia; a separate manual checkout is not required.

### Declarative configuration

Add the source and plugin ID to the v5 configuration:

```toml
[plugins]
enabled = [
  "goober/hydra-update-examiner",
  "goober/voxtype-suite",
  "goober/wallpaper-director",
]
auto_update = true

[[plugins.source]]
name = "goober-v5"
kind = "git"
location = "https://github.com/Go08er/goober-noctalia-plugins-v5"
enabled = true

[widget.hydra-readiness]
type = "goober/hydra-update-examiner:hydra"
use_shared_glyphs = false

[widget.voxtype]
type = "goober/voxtype-suite:voxtype"

[widget.wallpapers]
type = "goober/wallpaper-director:wallpapers"

[plugin_settings."goober/hydra-update-examiner"]
shared_display_mode = "on_hover"
```

Add the desired widget keys to a bar section using the rest of your normal bar
configuration. Place the Director shortcut through Noctalia's Control Center
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
noctalia msg plugins disable goober/voxtype-suite
noctalia msg plugins disable goober/wallpaper-director
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
noctalia msg plugins enable goober/voxtype-suite
noctalia msg plugins enable goober/wallpaper-director
```

Then add the desired entries from Noctalia's widget and Control Center editors.
Luau file edits hot-reload. Manifest edits are picked up on the next Noctalia
configuration reload. If the Git and path sources are both present, source
ordering determines which copy supplies a duplicate plugin ID; remove or
disable the Git source while developing if you want to avoid that ambiguity.

### VoxType Suite boundary

VoxType Suite listens to one extended `voxtype status --follow` stream and
forwards only supported recording start, stop, cancel, and on-demand diagnostic
commands. It never installs, starts, stops, updates, configures, or supervises
the VoxType daemon. The default bar gestures remain left toggle and
middle/right cancel. Advanced one-shot output/model/profile controls are off by
default.

Clipboard, paste, and file are explicit one-recording VoxType destinations.
The plugin does not read the clipboard or persist transcripts. File output is
exclusive rather than a simultaneous backup; see
[`voxtype-suite/README.md`](voxtype-suite/README.md) for the privacy and output
details.

### Wallpaper Director phase one

Wallpaper Director provides one configurable bar/Control Center entry point
for Noctalia's static wallpaper UI, Wallhaven, and W Engine. It detects optional
providers, retains saved unavailable actions, and exposes native
next/previous/random routing. Noctalia still owns static rendering, Wallhaven
still owns browsing/downloading, and W Engine remains the only
`linux-wallpaperengine` process owner.

Pairing, generated live-scene stills, static/live reels, and timer conflict
resolution remain staged until Noctalia has reliable external-wallpaper
lifecycle cleanup and W Engine has a narrow public adapter. The Hub does not
fake these features with competing processes or private-state edits. See
[`wallpaper-director/README.md`](wallpaper-director/README.md).

All three first-run gestures already have useful provider actions. Open the
configuration panel directly with
`noctalia msg panel-toggle goober/wallpaper-director:director`, then assign
**Open Wallpaper Director** to any gesture if you want a permanent UI route.
Its bar glyph is a native per-placement searchable selector, as are VoxType
Suite's idle, active, stopped, and unknown-state glyphs.

### Hydra Update Examiner customization

The plugin gear exposes channel, polling, threshold, shared text mode and
colors, plus optional plugin-wide shared glyph names. Current Noctalia renders
root plugin glyph settings as text fields. For its native searchable glyph
picker, middle-click a placed widget, leave **Use shared glyphs** off, and use
the button adjacent to each glyph field. **Use shared text and colors** is an
independent toggle, so placements can inherit those values while selecting
their own glyphs. Right-click opens the native action panel.

When updating from v0.2.0, `use_shared_presentation` continues to control text
and colors but no longer controls glyphs. V0.3.0 defaults the new
`use_shared_glyphs` widget setting to `false`; enable it on a placement only if
that placement should retain v0.2.0's plugin-wide glyph behavior.

Run the repository checks with:

```bash
python3 tools/validate.py
noctalia plugins lint hydra-update-examiner voxtype-suite wallpaper-director
python3 voxtype-suite/tests/check.py
python3 wallpaper-director/tests/test_contract.py
```

Run the native v5 integration test in a disposable NixOS VM with:

```bash
nix build -L .#vm-test
nix build -L .#vm-test-voxtype
nix build -L .#vm-test-wallpaper
```

The VM harnesses are pinned to the exact beta.7 host revision. They use
in-guest sources, headless Sway, software rendering, and deterministic command
fixtures without touching the host Noctalia session or configuration. The
original `vm-test` retains Hydra's render and glyph-picker coverage; the two
isolated checks exercise the new singleton services, failure boundaries, and
process-ownership rules. See `tests/vm/README.md` for details.

## Editor setup

The included `.luaurc` matches Noctalia's nonstrict plugin runtime. For host API
autocomplete and typo diagnostics, configure `luau-lsp` to use the current
[`noctalia.d.luau`](https://github.com/noctalia-dev/official-plugins/blob/main/noctalia.d.luau)
from the official plugin repository as a definition file. It is intentionally
not vendored here while the beta API is changing quickly.

## Publication status

This repository is a directly importable custom Git source for native v5
testing. The two new plugins remain local staging work until an explicit
publication step. None of the plugins has been submitted to, accepted into, or
registered with Noctalia's built-in official or community catalogs. See
`PORTING.md` and each plugin README for migration decisions and remaining work.

## License

MIT. See `LICENSE`.
