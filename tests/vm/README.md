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
| `vm-test-wall-in-one` | Provider policy, internal renderer ownership, persistent mixed reels, pairing/colors, MotionBGS offline protocol, persistence, and panel rendering |

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

The Wall-in-One suite imports all three production services beside controlled
Wallhaven, W Engine, and mpvpaper fixtures. It pins the `plugins list` grammar,
rejects look-alike status tokens, exercises provider panels and service IPC,
and verifies that every detected integration can be force-disabled without
disabling its provider plugin. `auto` prefers an enabled external plugin;
explicit `internal` plus that plugin is a fail-closed conflict. With providers
absent, the guest exercises Wall-in-One's internal W Engine and mpvpaper paths.
A provider-probe failure while an internal child is live makes ownership
unknown, disables both internal apply paths, and stops only that exact child;
a successful probe is required before internal rendering is re-enabled.

The renderer fixture records NUL-delimited argv and keeps each fake child alive
long enough to test replacement, pause/resume/toggle, stop, output ownership,
and teardown. Assertions pin `--layer bottom`, mpvpaper's configured
`--auto-pause FULL|MAX --auto-mode`, exact-PID signals, private `0600` FIFOs,
and cleanup on reload/disable. An unrelated renderer sentinel and external
provider PIDs must remain unchanged. The offline Python contract additionally
drives the production supervisor directly, so these invariants do not rely on
a real live-wallpaper renderer or compositor behavior.

Capture fixtures cover public Noctalia backing export, configured-video frame
extraction, cooperative W Engine capture, safe Workshop preview/source
fallback, durable per-output pairs, the dynamic pair registry, optional color
sync, animated-GIF-to-PNG manual pairing across reload, safe name-scoped startup
staging cleanup, and atomic temporary-file cleanup. The configured palette
output remains the one global leader; an explicit lock-screen image remains an
external override. The offline helper gate additionally rejects structurally
invalid WebP and header-only AVIF when no decoder is available.

A persistent schema-2 reel mixes static, video, and Workshop entries. The guest
drives start/stop/pause/resume/next/previous/random, checks schema-3 cursor,
history, shuffle-bag, and absolute next-due state, and reloads to prove both the
reel and runtime survive while the default start-on-load policy remains
disarmed. Static generation and renderer-event nonce assertions guard against a
late acknowledgement reviving an entry after stop or replacement. Distinct
persisted still images for the video and Workshop entries are asserted as the
actual backing selected before each renderer starts. Library discovery is
dynamically refreshed with six candidates: one production scan step consumes
the four-item budget, then ordinary update ticks publish the completed video
and Workshop inventory. Paused next/previous/random requests are rejected
without changing the cursor, history, or owned renderer state.

MotionBGS is tested without internet access. A guest-only conservative helper
returns pinned search/detail HTML and a tiny local MP4 through the exact
`WIO-MBG1` protocol. Tests cover same-origin parsing, bounded results, HD/4K
links, cache hits without another fetch, serialized commands, challenge and
unknown-markup failures, cross-origin rejection, atomic MP4 install, provenance
sidecar creation, clear, and status/results mirroring. The shipped helper's
local self-test runs before the fixture is substituted.

Storage assertions migrate legacy config/runtime documents to config schema 2
and runtime schema 3, preserve prior valid data in `.bak`, reject corrupt or
future state without overwriting evidence, and leave no `.tmp`, `.part`,
staging, FIFO, socket, or owned-child leaks. Static gates additionally pin the
8 MiB read/write ceiling, bounded nested maps/arrays/paths, deterministic pair
pruning, and active-capture staging cleanup on exit.

All suites treat Luau runtime errors, undeclared settings, failed hot reloads,
and missing glyph warnings as failures. Run the relevant target after any
plugin or harness change; a prior result does not certify the current tree.
