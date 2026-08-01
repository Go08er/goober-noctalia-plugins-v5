# Noctalia v5 VM tests

These tests boot disposable NixOS QEMU guests against the exact pinned
Noctalia `v5.0.0-beta.7` revision. They never launch Noctalia in the host
Wayland session or read or write the host Noctalia configuration.

Run one automated suite from the repository root:

```bash
nix build -L .#vm-test
nix build -L .#vm-test-nocvox
nix build -L .#vm-test-wall-in-one
```

| Package | Coverage |
| --- | --- |
| `vm-test` | Hydra rendering, actions, hot reload, settings, and native searchable glyph picker |
| `vm-test-nocvox` | NocVox singleton listener, state/control matrix, diagnostics, validation, privacy, and teardown |
| `vm-test-wall-in-one` | Provider discovery/control, still capture and pairing, color policy, persistence, panel rendering, and renderer ownership boundaries |

Each suite also exposes an interactive driver by adding `-driver` to its
package name. For example:

```bash
nix build .#vm-test-wall-in-one-driver
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
widget presentations; native action defaults; service, widget, and panel IPC;
hover rendering; all three hot-reload paths; correctly scoped polling and
appearance settings; the response helper; screenshots; and keyboard opening of
Noctalia's native searchable glyph menu.

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

## Wall-in-One

The Wall-in-One suite imports the coordinator beside controlled Wallhaven,
W Engine, and mpvpaper fixtures. It pins the beta.7 `plugins list` grammar;
rejects incompatible or look-alike status tokens; exercises the documented
provider panels and service commands; checks atomic configuration and runtime
state across reload; and renders the attached hub.

Capture fixtures cover a configured video and a configured W Engine project,
verify output in the selected directory, and record the resulting
`setWallpaper` and color-scheme requests. Multi-output assertions keep
Noctalia's global-palette rule explicit: the configured palette output is the
leader, while the last paired output wins when no leader is selected. An
explicit lock-screen image remains an external override; the plugin only
persists the paired wallpaper and never rewrites lock-screen configuration.

W Engine discovery remains a cooperative, versioned adapter because v5 has no
public cross-plugin status API. The guest verifies the handshake boundary and
safe video/preview fallback; no process arguments or provider-private state are
inspected, no second renderer is started, and the live renderer sentinel and
provider-owned schedules remain untouched.

All suites treat Luau runtime errors, undeclared settings, failed hot reloads,
and missing glyph warnings as failures. Run the relevant target after any
plugin or harness change; a prior result does not certify the current tree.
