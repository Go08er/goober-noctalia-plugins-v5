# Noctalia v5 VM tests

These tests boot disposable NixOS QEMU guests against pinned Noctalia tag
`v5.0.0-beta.7`, whose project/runtime version is `5.0.0`. They never launch
Noctalia in the host Wayland session or read or write the host Noctalia
configuration.

Run one automated suite from the repository root:

```bash
nix build -L path:.#vm-test
```

Use the explicit `path:.` source while developing: Git-backed flake evaluation
omits untracked files, which can make a new manifest entry appear to be missing
inside the guest. Once every file is committed, `.#...` is equivalent.

| Package | Coverage |
| --- | --- |
| `vm-test` | Hydra rendering, actions, hot reload, settings, and native searchable glyph picker |

Each suite also exposes an interactive driver by adding `-driver` to its
package name. For example:

```bash
nix build -L path:.#vm-test-driver
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

All suites treat Luau runtime errors, undeclared settings, failed hot reloads,
and missing glyph warnings as failures. Run the relevant target after any
plugin or harness change; a prior result does not certify the current tree.
