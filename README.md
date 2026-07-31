# Goober Noctalia v5 Plugins

Source prepared for public testing against the native Noctalia v5 runtime. This
tree is intentionally separate from the Quickshell-based v4.7 repository in
`../noctalia_4.7`.

The v5 plugin API is currently beta. Manifests and runtime APIs can still
change before Noctalia v5 is stable, so this source should be treated as a
development workspace rather than a released plugin feed.

## Available staging plugins

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

## Local development

Point a Noctalia v5 path source at this directory; do not point it at the HUE
workspace parent. Replace the example path with the checkout's absolute path:

```bash
noctalia msg plugins source add goober-hue-dev path /absolute/path/to/noctalia_5
noctalia msg plugins enable goober/hydra-update-examiner
```

Then add `goober/hydra-update-examiner:hydra` from the bar widget picker.
Luau file edits hot-reload. Manifest edits are picked up on the next Noctalia
configuration reload.

Run the repository checks with:

```bash
python3 tools/validate.py
```

Run the native v5 integration test in a disposable NixOS VM with:

```bash
nix build -L .#vm-test
```

The VM harness is pinned to the exact beta.7 host revision. It
uses headless Sway, software rendering, and fixed Hydra responses to check real
plugin/service/widget startup, IPC, the open action, hot reload, and a guest
screenshot without touching the host Noctalia session or configuration. The
complete beta.7/API 3 run passed on 2026-07-31. See `tests/vm/README.md` for
details.

## Editor setup

The included `.luaurc` matches Noctalia's nonstrict plugin runtime. For host API
autocomplete and typo diagnostics, configure `luau-lsp` to use the current
[`noctalia.d.luau`](https://github.com/noctalia-dev/official-plugins/blob/main/noctalia.d.luau)
from the official plugin repository as a definition file. It is intentionally
not vendored here while the beta API is changing quickly.

## Publication status

This tree is prepared as a standalone public test repository so native v5
testing can begin independently of the archived v4 project. It has not been
submitted to or registered with an upstream Noctalia catalog. See `PORTING.md`
for the migration decisions and remaining work.

## License

MIT. See `LICENSE`.
