# Noctalia v5 VM test

This test boots a disposable NixOS QEMU guest and runs the public-test plugin
against the exact Noctalia v5.0.0-beta.7 source revision. It does not launch
Noctalia v5 in the host Wayland session or read/write the host Noctalia
configuration.

Run the automated test from the repository root:

```bash
nix build -L .#vm-test
```

For exploratory testing, build the interactive test driver:

```bash
nix build .#vm-test-driver
./result/bin/nixos-test-driver
```

The guest uses headless Sway because Noctalia's bar needs a real Wayland
compositor with `zwlr_layer_shell_v1`, an output, and EGL/GLES2. Rendering uses
Mesa software paths; no host desktop or GPU session is shared.

The automated path is intentionally offline and deterministic. The guest first
commits the staged source into a local Git repository, then adds its `file://`
URL through the same `plugins source add ... git ...` IPC used for GitHub. This
tests the Git-source implementation without relying on GitHub or exposing the
host session. Fixture versions of `curl` and `xdg-open` return a successful
Hydra `launched` result and record requests inside the guest. The test then
checks:

- beta.7 native plugin lint and config validation;
- source addition through IPC and lazy Git cloning on enable;
- root `catalog.toml` discovery from a no-checkout Git cache;
- export into Noctalia's managed materialized-plugin directory;
- layer-shell, plugin discovery, service startup, and construction of two
  widgets plus the attached panel;
- shared presentation defaults and per-placement appearance overrides;
- service and widget IPC dispatch;
- the widget-to-service open action;
- `on_hover` hidden and visible rendering through the production callback;
- panel rendering plus its documentation and API 15 scoped-settings actions;
- guest-only service, widget, and panel hot reload;
- the real shell helper against fixed Hydra responses; and
- `grim` captures of the bar, hover states, action panel, and settings surface.

The fixture is an integration boundary, not a replacement for parser tests.
Recorded response fixtures for every Hydra state remain a separate milestone.

## Last result

The automated run passed on 2026-07-31 against the pinned beta.7 host with
plugin API 15. It passed native lint/config validation and exercised Git-source
cloning, catalog discovery, plugin materialization, two presentation scopes,
the rendered `Launched` state, service/widget IPC, hover state rendering, the
attached panel, documentation and scoped-settings actions, all three hot-reload
paths, screenshot capture, and clean shutdown.

The headless compositor exposes no physical pointer, so the automated hover
probe calls the production `onHover(true)` callback through a temporary guest
hot reload and confirms that the rendered crop changes. Physical pointer
dispatch, actual button presses and settings edits, manifest reload, a live
GitHub network clone, and the remaining Hydra states still require exploratory
VM coverage.
