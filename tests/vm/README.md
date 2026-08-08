# Noctalia v5 VM tests

These tests boot disposable NixOS QEMU guests against pinned Noctalia tag
`v5.0.0-beta.7`, whose project/runtime version is `5.0.0`. They never launch
Noctalia in the host Wayland session or read or write the host Noctalia
configuration.

Run one automated suite from the repository root:

```bash
nix build -L path:.#vm-test
nix build -L path:.#vm-test-nocvox
```

Use the explicit `path:.` source while developing: Git-backed flake evaluation
omits untracked files, which can make a new manifest entry appear to be missing
inside the guest. Once every file is committed, `.#...` is equivalent.

| Package | Coverage |
| --- | --- |
| `vm-test` | Hydra rendering, actions, hot reload, settings, and native searchable glyph picker |
| `vm-test-nocvox` | NocVox singleton listener, state/control matrix, diagnostics, validation, privacy, and teardown |

Each suite also exposes an interactive driver by adding `-driver` to its
package name. For example:

```bash
nix build -L path:.#vm-test-nocvox-driver
./result/bin/nixos-test-driver
```

The guests use headless Sway because Noctalia's bar needs a real Wayland
compositor with `zwlr_layer_shell_v1`, an output, and EGL/GLES2. Rendering uses
Mesa software paths; no host desktop or GPU session is shared.

The automated path is offline and deterministic. Each guest commits its staged
catalog source into a local Git repository and adds that `file://` source using
the same `plugins source add ... git ...` IPC used for GitHub. This exercises
catalog discovery, lazy clone, and managed plugin materialization without
network access. Provider and external-command behavior comes from bounded guest
fixtures.

## Hydra Update Examiner

The Hydra suite covers the pinned beta.7 source's native lint and config
validation; two independent widget presentations; native action defaults;
service, widget, and panel IPC; hover rendering; all three hot-reload paths;
correctly scoped polling and appearance settings; the response helper;
screenshots; and keyboard opening of Noctalia's native searchable glyph menu.

The headless compositor has no physical pointer, so the hover probe calls the
production `onHover(true)` callback through a temporary guest-only hot reload.
Physical pointer dispatch, choosing and applying a different glyph, live GitHub
network cloning, and the remaining Hydra response states remain exploratory
coverage.

## NocVox

The NocVox suite imports and enables the real plugin, creates two placements,
and verifies there is exactly one long-lived status follower. It covers normal,
malformed, and future status values; state-aware toggle/stop/cancel; command
failure recovery; diagnostics and a reload while diagnostics are pending; safe
fixed recording commands with no per-recording flags; attached-panel rendering;
missing glyph detection; and disable cleanup without stopping the externally
owned daemon sentinel. Static coverage separately rejects every NocVox desktop
notification call.

All suites treat Luau runtime errors, undeclared settings, failed hot reloads,
and missing glyph warnings as failures. Run the relevant target after any
plugin or harness change; a prior result does not certify the current tree.
