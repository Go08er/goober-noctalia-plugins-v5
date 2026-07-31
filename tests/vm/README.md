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
- layer-shell, plugin discovery, service startup, and widget construction;
- service and widget IPC dispatch;
- the widget-to-service open action;
- guest-only service and widget hot reload;
- the real shell helper against fixed Hydra responses; and
- a `grim` capture of the headless output.

The fixture is an integration boundary, not a replacement for parser tests.
Recorded response fixtures for every Hydra state remain a separate milestone.

## Last result

The automated run passed on 2026-07-31 against the pinned beta.7 host while the
plugin retained API 3. It passed native lint/config validation and exercised
Git-source cloning, catalog discovery, plugin materialization, the rendered
`Launched` state, service/widget IPC, the open action, both hot-reload paths,
screenshot capture, and clean shutdown. Pointer clicks, settings-panel
interaction, manifest reload, a live GitHub network clone, and the remaining
Hydra states still require exploratory VM coverage.
