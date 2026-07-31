# Noctalia v5 VM tests

These tests boot disposable NixOS QEMU guests against the exact pinned
Noctalia `v5.0.0-beta.7` revision. They never launch Noctalia in the host
Wayland session or read or write the host Noctalia configuration.

Run one automated suite from the repository root:

```bash
nix build -L .#vm-test
nix build -L .#vm-test-voxtype
nix build -L .#vm-test-wallpaper
```

| Package | Coverage |
| --- | --- |
| `vm-test` | Hydra rendering, actions, hot reload, settings, and native searchable glyph picker |
| `vm-test-voxtype` | VoxType singleton listener, state/control matrix, diagnostics, validation, privacy, and teardown |
| `vm-test-wallpaper` | Provider routing, persistence, corrupt-state handling, panel rendering, and W Engine ownership boundary |

Each suite also exposes an interactive driver by adding `-driver` to its
package name. For example:

```bash
nix build .#vm-test-wallpaper-driver
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

The Hydra suite covers beta.7 native lint and config validation; two independent
widget placements; shared/local text, color, and glyph inheritance; service,
widget, and panel IPC; hover rendering; all three hot-reload paths; scoped
settings; the response helper; screenshots; and keyboard opening of Noctalia's
native searchable glyph menu.

The headless compositor has no physical pointer, so the hover probe calls the
production `onHover(true)` callback through a temporary guest-only hot reload.
Physical pointer dispatch, choosing and applying a different glyph, live GitHub
network cloning, and the remaining Hydra response states remain exploratory
coverage.

## VoxType Suite

The VoxType suite imports and enables the real plugin, creates two placements,
and verifies there is exactly one long-lived status follower. It covers normal,
malformed, and future status values; state-aware toggle/stop/cancel; command
failure recovery; diagnostics and a reload while diagnostics are pending; safe
shell quoting; invalid override rejection; attached-panel rendering; missing
glyph detection; and disable cleanup without stopping the externally owned
daemon sentinel.

## Wallpaper Director

The Wallpaper suite imports Director beside controlled Wallhaven and W Engine
fixtures. It pins the exact beta.7 `plugins list` grammar; rejects incompatible
or look-alike status tokens; tests renderer-command disappearance and recovery;
opens both provider panels; routes only the fixed native wallpaper IPC; checks
atomic config/backups across reload; renders the Director panel; preserves
corrupt user data without overwriting it; and proves that no W Engine command,
private data, or external renderer sentinel is touched.

## Last result

All three automated suites passed on 2026-07-31 against the pinned beta.7 host.
The two new plugin suites also treat Luau runtime errors, undeclared settings,
failed hot reloads, and missing glyph warnings as failures.
