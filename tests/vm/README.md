# Noctalia v5 VM tests

These tests boot disposable NixOS QEMU guests against pinned Noctalia tag
`v5.0.0-beta.7`, whose project/runtime version is `5.0.0`. They never launch
Noctalia in the host Wayland session or read or write the host Noctalia
configuration.

Run one automated suite from the repository root:

```bash
nix build -L path:.#vm-test
nix build -L path:.#vm-test-nocvox
nix build -L path:.#vm-test-wall-in-one
```

Use the explicit `path:.` source while developing: Git-backed flake evaluation
omits untracked files, which can make a new manifest entry appear to be missing
inside the guest. Once every file is committed, `.#...` is equivalent.

| Package | Coverage |
| --- | --- |
| `vm-test` | Hydra rendering, actions, hot reload, settings, and native searchable glyph picker |
| `vm-test-nocvox` | NocVox singleton listener, state/control matrix, diagnostics, validation, privacy, and teardown |
| `vm-test-wall-in-one` | Five-service startup, provider policy, reusable pairings/playlists, month-aware schedules, adaptive palette and provider-thumbnail rendering, internal renderer ownership and crash backoff, MotionBGS fixtures, schema-3→4/runtime-6 migration, panel compilation/IPC, and teardown persistence |

Each suite also exposes an interactive driver by adding `-driver` to its
package name. For example:

```bash
nix build -L path:.#vm-test-wall-in-one-driver
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

## Wall-in-One

The complete schema-4/runtime-6, palette, native-Wallhaven, managed-MotionBGS,
and playlist VM is the authoritative integration gate. Run `nix build -L
path:.#vm-test-wall-in-one` after any plugin or harness change; an older result
is not evidence for a changed staging tree.

The Wall-in-One suite imports all five production services (`coordinator`,
`renderer`, `motionbgs`, `palettes`, and `wallhaven`) beside controlled
Wallhaven-panel, W Engine, and mpvpaper fixtures. It pins the `plugins list`
grammar, rejects look-alike status tokens, exercises provider panels and service
IPC, checks versioned palette/Wallhaven state, and verifies that every detected
integration can be force-disabled without disabling its provider plugin. `auto`
prefers an enabled external plugin; explicit `internal` plus that plugin is a
fail-closed conflict. With providers absent, the guest exercises Wall-in-One's
internal W Engine and mpvpaper paths. A provider-probe failure while an internal
child is live makes ownership unknown, disables both internal apply paths, and
stops only that exact child; a successful probe is required before internal
rendering is re-enabled. The exhaustive Wallhaven API/CDN download and palette
inventory negative cases remain deterministic offline-contract coverage rather
than claims about a live network. Adaptive wallpaper palette preview is
deterministic in the guest: the fixture pins the exact `noctalia theme <image>
--scheme m3-rainbow --both -o <private-json>` argument order and verifies the
published dark/light surface and accent roles without changing the active
theme.

Before opening the attached hub, the suite compiles the exact materialized
`panel.luau` with the pinned Luau compiler. It then requires a real panel-open
log, a changed compositor screenshot, a provider probe initiated by `onOpen`,
and successful panel IPC. Luau load failures, `onOpen` failures, and local-
register exhaustion fail the gate explicitly.

Wallhaven and MotionBGS thumbnail presentation is also exercised without the
internet. The shipped thumbnail helper first runs its own boundary self-test;
the guest then substitutes an exact-protocol helper that installs two distinct
local PNG fixtures. The real provider panes must render those colors through
`ui.image`, write a bounded manifest with valid local files, reuse both entries
when the fixture rejects every cache miss, and leave no staging or manifest
temporary behind.

The renderer fixture records NUL-delimited argv and keeps each fake child alive
long enough to test replacement, pause/resume/toggle, stop, output ownership,
and teardown. The VM pins the configured `--layer background` path while the
offline contract validates both accepted `background`/`bottom` values,
mpvpaper's configured `--auto-pause --auto-mode <FULL|MAX|ACTIVE>`, private mpv
audio IPC, Wallpaper Engine signal controls, exact-PID signals, private `0600`
FIFOs, and cleanup on reload/disable. Different outputs can own different
backends concurrently; a same-output switch stops the exact old child before
the replacement starts. An unrelated renderer sentinel and external provider
PIDs must remain unchanged. A child that exits after the startup probe is
subject to bounded exponential restart backoff, and a stable replacement must
clear that crash streak before normal playlist recovery resumes. The offline
Python contract additionally drives the production supervisor directly, so
these invariants do not rely on a real live-wallpaper renderer or compositor
behavior.

Capture fixtures cover public Noctalia backing export, configured-video frame
extraction, exact-owner `linux-wallpaperengine --screenshot` capture,
cooperative W Engine capture, safe Workshop preview/source fallback, validated
private-staging promotion, durable per-output pairs, active internal Workshop
state, the dynamic pair registry, optional color sync, animated-GIF-to-PNG
manual pairing across reload, safe name-scoped startup staging cleanup, and
atomic temporary-file cleanup. The configured palette output remains the one
global leader; an explicit lock-screen image remains an external override. The
offline helper gate additionally rejects structurally invalid WebP and
header-only AVIF when no decoder is available.

A persistent config-schema-4 named playlist mixes static, video, and Workshop
occurrences linked to reusable catalog pairings. A separate explicit schema-3
fixture proves migration creates those catalog links, defaults an omitted month
filter to all twelve months, removes numeric priority, and retains the original
schema-3 document as the migration backup. The guest exercises pairing save,
linked-occurrence synchronization, add, stable-ID placement, and safe catalog
deletion that detaches but preserves a playlist snapshot. It also pins
per-output shuffle/interval overrides and clean inheritance back to playlist
defaults. The guest drives start/stop/pause/resume/next/previous/random, checks
runtime-schema-6 stable entry IDs, cursor/history/shuffle-bag and absolute
next-due state, and reloads to prove the playlist and runtime survive while the
default start-on-load policy remains disarmed. The output-specific one-entry
Quick Choice path is expected to park instead of becoming a timer. Static
generation and renderer-event nonce assertions guard against a late
acknowledgement reviving an entry after stop or replacement. Distinct persisted
still images for the video and Workshop entries are asserted as the actual
backing selected before each renderer starts. Two enabled overnight schedule
rows target a month other than the current guest month; a deterministic probe
verifies the lower matching row wins and an adjacent month does not match,
without letting the fixture alter the live test sequence.
Library discovery is dynamically refreshed with six candidates: one production
scan step consumes the four-item budget, then ordinary update ticks publish the
completed video and Workshop inventory. Paused next/previous/random requests are
rejected without changing the entry ID, history, or owned renderer state.

Image/video roots are exercised as separate and shared locations. The suite
distinguishes user-owned files from marked managed children, requires sidecars
before exposing deletion, installs automatic pairs beneath
`Wall-in-One/Automatic Stills`, and verifies that deleting a managed MotionBGS
video removes only its managed automatic still. Native Wallhaven downloads are
managed only when their exact `.wallhaven.json` sidecar validates; files written
by the separate official plugin remain user-owned and non-deletable here.

MotionBGS is tested without internet access. A guest-only conservative helper
returns pinned search/detail HTML and a tiny local MP4 through the exact
`WIO-MBG1` protocol. Tests cover same-origin parsing, bounded results, HD/4K
links, the same route validation used for pageable latest/genre/4K catalogs, a
36-card pageable genre fixture, per-page cache hits without another
fetch, rejection of the site's broken HD-page shape before transport,
serialized commands, challenge and
unknown-markup failures, cross-origin rejection, atomic MP4 install, provenance
sidecar creation, clear, and status/results mirroring. Provider previews use a
second exact-protocol fixture and real image pixels. The shipped helper's
local self-test runs before the fixture is substituted.

The guest currently seeds a config-schema-3 playlist/schedule fixture and a
runtime-schema-1 pair fixture, confirms migration to config schema 4 and runtime
schema 6, then checks linked pairing snapshots, migration backups,
corrupt-state fail-closed behavior, and cleanup of `.tmp`, `.part`, staging,
FIFO, socket, and owned-child artifacts. The offline contract covers the wider
supported config-schema-1/2 and runtime-schema-1–5 migration matrix, coordinated
transaction recovery, the 8 MiB read/write ceiling, bounded nested
maps/arrays/paths, deterministic pair pruning, stable playlist entry IDs, and
active-capture staging cleanup. Extending the VM itself across every legacy
schema and interruption stage remains an unchecked gate.

Disable is also a persistence boundary. The suite observes the palette
service's bounded terminal state from inside its owning plugin runtime, proves
all owned renderer children are gone, and requires Noctalia's wallpaper, theme
mode, and color-scheme values to remain exactly unchanged. This deliberately
leaves the last pairing's static backing and colors ready for the next desktop
start while the dynamic layer is absent.

All suites treat Luau runtime errors, undeclared settings, failed hot reloads,
and missing glyph warnings as failures. Run the relevant target after any
plugin or harness change; a prior result does not certify the current tree.
