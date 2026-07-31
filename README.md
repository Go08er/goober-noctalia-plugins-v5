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
| `goober/hydra-update-examiner` | `0.1.0` | Beta.7/API 3 VM-tested; retained shell backend |

## Repository layout

```text
catalog.toml
hydra-update-examiner/
  plugin.toml
  README.md
  thumbnail.webp
  service.luau
  widget.luau
  translations/en.json
  scripts/hydra-channel-progress
tools/validate.py
flake.nix
flake.lock
tests/vm/
```

Noctalia v5 discovers Git sources through `catalog.toml`. Each plugin lives in
a root directory matching the plugin part of its `author/plugin` id. The source
and manifest both declare `plugin_api = 3`, intentionally retaining the oldest
compatibility level that provides every capability used by this port. The
v5.0.0-beta.7 host accepts cumulative plugin API levels through 20, so adopting
a newer level without using one of its capabilities would only narrow host
compatibility.

## Install from GitHub

Repository URL:

```text
https://github.com/Go08er/goober-noctalia-plugins-v5
```

Plugin ID:

```text
goober/hydra-update-examiner
```

### Settings interface

1. Open **Settings**, select **Plugins**, and add a plugin source.
2. Choose **Git**, use `goober-v5` as the source name, and enter the repository
   URL above.
3. Enable `goober/hydra-update-examiner` after the source finishes loading.
4. Add `goober/hydra-update-examiner:hydra` from the bar widget picker.

The source name is only a local handle. `goober-v5` is used throughout this
README so the CLI and configuration examples agree.

### Command line

```bash
noctalia msg plugins source add goober-v5 git https://github.com/Go08er/goober-noctalia-plugins-v5
noctalia msg plugins enable goober/hydra-update-examiner
noctalia msg plugins list
```

Then add `goober/hydra-update-examiner:hydra` from the bar widget picker.
The source is cloned and managed by Noctalia; a separate manual checkout is not
required.

### Declarative configuration

Add the source and plugin ID to the v5 configuration:

```toml
[plugins]
enabled = ["goober/hydra-update-examiner"]
auto_update = true

[[plugins.source]]
name = "goober-v5"
kind = "git"
location = "https://github.com/Go08er/goober-noctalia-plugins-v5"
enabled = true

[widget.hydra-readiness]
type = "goober/hydra-update-examiner:hydra"
```

Add `hydra-readiness` to the desired bar section using the rest of your normal
bar configuration. When declaring `[[plugins.source]]` entries yourself,
retain any other plugin sources you still want configured.

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
```

Then add `goober/hydra-update-examiner:hydra` from the bar widget picker.
Luau file edits hot-reload. Manifest edits are picked up on the next Noctalia
configuration reload. If the Git and path sources are both present, source
ordering determines which copy supplies a duplicate plugin ID; remove or
disable the Git source while developing if you want to avoid that ambiguity.

Run the repository checks with:

```bash
python3 tools/validate.py
```

Run the native v5 integration test in a disposable NixOS VM with:

```bash
nix build -L .#vm-test
```

The VM harness is pinned to the exact beta.7 host revision. It uses an in-guest
Git source, headless Sway, software rendering, and fixed Hydra responses to
check catalog discovery, clone and materialization, real plugin/service/widget
startup, IPC, the open action, hot reload, and a guest screenshot without
touching the host Noctalia session or configuration. The complete beta.7/API 3
run passed on 2026-07-31. See `tests/vm/README.md` for details.

## Editor setup

The included `.luaurc` matches Noctalia's nonstrict plugin runtime. For host API
autocomplete and typo diagnostics, configure `luau-lsp` to use the current
[`noctalia.d.luau`](https://github.com/noctalia-dev/official-plugins/blob/main/noctalia.d.luau)
from the official plugin repository as a definition file. It is intentionally
not vendored here while the beta API is changing quickly.

## Publication status

This repository is a directly importable custom Git source for native v5
testing. It has not been submitted to, accepted into, or registered with
Noctalia's built-in official or community catalogs. See `PORTING.md` for the
migration decisions and remaining work.

## License

MIT. See `LICENSE`.
