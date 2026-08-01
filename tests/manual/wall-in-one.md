# Wall-in-One 0.4 manual test

Use an isolated Noctalia v5 profile or the VM test. Do not install optional
providers merely to make a capability card green, and do not point a manual
test at irreplaceable Wallpaper Engine data.

## Install and customization

1. Import the repository through Noctalia's Git source flow and enable
   `goober/wall-in-one` from its catalog entry. Confirm all three services
   (`coordinator`, `renderer`, and `motionbgs`) start and the hub, shortcut, and
   `goober/wall-in-one:wall-in-one` widget load without undeclared-setting,
   glyph, or Luau errors.
2. Add two widget placements. Give them different glyphs, labels, label
   visibility, and colors. Open Noctalia's native searchable icon selector from
   each placement, choose different icons, reload, and confirm each placement
   keeps its own choice.
3. Change the left, middle, and right gesture mappings in the hub. Exercise a
   native action, a provider panel, a capture action, a scheduler action, and
   **Open Wall-in-One**. Reload and confirm the schema-2 gesture map persists.
4. Add the Control Center shortcut. Left and right mappings must work; the
   shortcut must not synthesize a middle-click callback.

## Backend policy and ownership

Test W Engine and mpvpaper independently with `auto`, `external`, and
`internal` backend selection.

| Selection | External plugin enabled | Expected effective backend |
| --- | --- | --- |
| `auto` | Yes | `external`; Wall-in-One routes only documented panel/service controls |
| `auto` | No, command installed | `internal`; apply controls are enabled |
| `external` | Yes | `external` |
| `external` | No | `none`; fail closed |
| `internal` | No, command installed | `internal` |
| `internal` | Yes | conflict, `none`; fail closed without launching a second renderer |

For each provider, disable its `Use …` switch and confirm both external and
internal actions become unavailable. Re-enabling it must require a fresh
provider probe. Exact-token parsing must reject `enabled-ish`, `disabled`, and
`enabled incompatible` plugin-list fixtures.

While an internal child is running, make the provider-ownership probe fail.
`probe_ok` must become false, both effective backends and apply capabilities
must fail closed, and the exact owned child must stop while an unrelated
sentinel remains alive. No internal child may restart until a successful probe
establishes that no external owner exists.

Disconnect an output, then send an action carrying that stale explicit output
name. The action must fail for the missing output; it must not silently retarget
the currently focused display.

In internal mode, apply one Workshop item and one video on each available
output. Check the child command lines:

- `linux-wallpaperengine` receives the numeric ID, selected scaling/clamp,
  bounded FPS/audio/feature flags, the exact output, and `--layer bottom`;
- `mpvpaper` receives the exact absolute video and output, `--layer bottom`,
  configured mute/hardware decoding, and when enabled
  `--auto-pause FULL|MAX --auto-mode`;
- pause, resume, toggle, replacement, and stop affect only the exact PID owned
  for that output;
- disconnecting an owned output, changing its effective backend, disabling the
  plugin, reloading its renderer service, or exiting Noctalia stops every owned
  child and removes that instance's FIFO/socket/log files;
- an unrelated long-running process and an external provider process keep the
  same PID throughout.

Never accept `pgrep`, `pkill`, `killall`, name matching, detached sessions, or a
global mpv socket as ownership. The supervisor's private FIFO must be mode
`0600`, reject stale/non-monotonic nonces and malformed field counts, and keep
one bounded child/log per output.

## Provider discovery and cooperative capture

With Wallhaven, W Engine, and mpvpaper fixtures enabled, open their panels and
exercise their documented service controls. W Engine capability/current state
must come only from the versioned cooperative adapter. Suppress its response,
probe again, and confirm the lease expires after the grace period.

For a cooperative rendered capture, require a unique
`pluginDataDir()/staging/*.png` request path. Reject a stale request ID, an
alternate returned path, an empty file, or a late response. Accept only the
exact requested PNG after decode validation, atomically install it in the
capture destination, drain queued work, and remove staging files on every
terminal path.

Queue requests A, B, and C for the same output while A is still running. Only
the newest waiting request, C, may run after A; B must receive a replaced
result and any staging file it owned must be removed. Repeat with cooperative
adapter requests and confirm the queued scene ID is likewise latest-wins.
Disconnect the output or change its provider/current-scene observation before
a capture completes: the durable export may finish, but it must not become the
output's pair or start a stale renderer.

Without an adapter, a configured numeric Workshop item may use a validated
local source frame or preview. It must be described as a source/preview
fallback, not as proof of the currently rendered scene. The coordinator must
not inspect process arguments or another plugin's private files.

## Pairing, colors, and capture

1. Leave `capture_directory` empty and confirm exports use Noctalia's configured
   wallpaper directory (with `pluginDataDir()/captures` only as an API fallback).
   Then choose an absolute directory and confirm subsequent exports use it. A
   relative path, dot-segment path, or `/` must fail closed.
2. Export the public `wallpaper-get <output>` backing while all live-provider
   integrations are disabled. It should copy the validated image without
   pairing it back or accessing provider-private state.
3. Export a configured video at frame 0 and a later frame. With `ffmpeg`
   removed, video/animated extraction must fail without changing the previous
   pair; static signature validation remains usable.
4. Pair a durable PNG/JPEG/WebP file and an animated GIF. WebP fallback
   validation must verify RIFF length/chunk structure, not just its magic bytes.
   AVIF must be decoder-validated and therefore fail closed when `ffmpeg` is
   unavailable. GIF pairing must
   persist a decoded PNG frame when `ffmpeg` is available and fail without
   changing the prior pair when it is not. A backing-only GIF export may remain
   GIF when no conversion is requested. A truncated or mislabeled image must
   be rejected. Temporary files must be beside the destination, use a
   non-image `.part` name, and be atomically promoted only after validation.
5. Pair different static representatives on two outputs. Confirm
   `runtime.pairs[output]` and the dynamic `pair_registry` retain both mappings
   across reload. Reapplying the same video/Workshop entry should reuse its
   validated cached pair.
6. Keep color sync off and confirm Wall-in-One issues no explicit palette
   request. Enable it, choose each supported scheme, and confirm the configured
   palette output is the single global leader. Without a leader, document that
   Noctalia's most recently applied pair wins.
7. Test both lock-screen configurations: a lock screen following the persisted
   wallpaper follows the pair; an explicit lock-screen image remains an
   external override and is never rewritten by this plugin.

Interrupt a capture and confirm no partial destination, stale staging file, or
`.part` file remains.

## Persistent mixed scheduler

For one output, create a reel containing a static image, a video, and a numeric
Workshop entry. Set a short safe interval and test `sequential`, `shuffle`, and
`random` order.

1. Start, pause, resume, advance, go back, choose random, and stop. The hub must
   accurately show running/paused state, cursor, last entry, history, and next
   due time.
   While paused, next/previous/random must be disabled and direct IPC attempts
   must leave the cursor, history, selected entry, and paused renderer unchanged.
2. While a live entry is starting, immediately stop, advance, or change the
   backend. A late renderer acknowledgement must not revive the invalidated
   generation or overwrite a newer selection.
3. Replace an owned live child with a static entry; the child must stop before
   the static pair is applied. If a renderer exits unexpectedly while its cycle
   is still active, the cycle may schedule a retry, but an intentional stop
   must not.
4. Give the video and Workshop entries distinct durable `still_path` values.
   Cycling to each entry must apply its own stored still, never an unrelated
   current output pair. Remove one stored still and confirm only that entry
   falls back to its fingerprint-validated dynamic-pair cache or a fresh
   capture.
5. Reload with a running reel while **start on load** is off. Its schema-2
   definition and history must survive, but the schema-3 state must be disarmed
   (`running=false`, `paused=false`, `next_due=0`). Enable **start on load**
   separately and confirm only non-empty reels are armed.
6. Remove entries and clear the reel. Cursor/history/shuffle-bag state must be
   normalized and an empty reel must stop its owned renderer.

The video/Workshop library scan bounds candidate examination and performs
metadata/JSON work incrementally after each directory listing. After changing
a source directory or requesting refresh, allow update ticks to finish and
wait for `library.scanning=false`; do not treat an immediate partial list as
the completed inventory. The host `listDir` call itself may still materialize
the directory before those per-tick bounds apply, so include a very large
directory in exploratory responsiveness testing.

## MotionBGS best-effort provider

MotionBGS exposes public pages rather than a stable API, so begin with the
offline fixture used by the VM test.

1. Search a fixture containing same-origin cards with `span.ttl`, thumbnails,
   and numeric media IDs. Result count must obey the configured 1–24 bound.
2. Open details containing same-origin HD/4K `/dl/<quality>/<id>/` links. Then
   request the same search/details inside the cache TTL and confirm no second
   helper fetch occurs.
3. Feed an anti-bot challenge, unknown markup, cross-origin redirect, unsafe
   URL, oversized response, invalid content type, and malformed helper status.
   Each must fail closed with a bounded diagnostic; no browser automation or
   challenge bypass is allowed.
4. Download the local MP4 fixture. Confirm bounded size/time, an MP4 signature,
   atomic install, and the adjacent `.motionbgs.json` provenance sidecar. The
   download directory falls back to `video_directory` only when the dedicated
   directory is empty.
5. Test clear, monotonic command nonces, bounded queueing, serialized requests,
   result/status mirroring in the coordinator, and the direct website fallback
   when the public-page adapter is unavailable. Clear or disable the provider
   during an in-flight fixture request and confirm its late completion cannot
   repopulate cache/results or publish a success acknowledgement.

Live-site behavior is exploratory because site markup can change. Do not make a
release depend on a successful public-network request.

## Storage and failure recovery

After several mappings, pairings, and reel edits, inspect plugin data:

- `config.json` is schema 2 and contains `gestures` plus per-output `reels`;
- `runtime.json` is schema 3 and contains provider observations, per-output
  `pairs`, `pair_registry`, and per-output `cycles`;
- valid schema-1 config and schema-1/2 runtime fixtures migrate once without
  losing mappings, provider observations, or pairs;
- a second successful write rotates the prior valid document into `.bak`, and
  no `.tmp` remains;
- corrupt or future-schema JSON is preserved as evidence, diagnostics explain
  the problem, and mutating actions fail closed rather than recreating defaults.

Both documents have an 8 MiB read/write ceiling. Exercise over-limit config and
runtime files plus malformed nested maps: more than 64 outputs, more than 1024
dynamic pairs, overlong paths/keys, oversized reel/history/shuffle arrays, and
invalid nested pair/cycle/capture records must all fail closed without
overwriting the evidence. At the limits, successful writes must prune oldest
pair-map entries deterministically rather than growing without bound.

Before startup, place more than 512 files in `pluginDataDir()/staging`, mixing
Wall-in-One `capture-<safe-id>.png` names with unrelated names and extensions.
Startup cleanup must inspect at most its bounded batch and remove only its own
matching staging files. Exit during adapter and queued captures and confirm
their known staging paths are removed without touching unrelated files. Repeat
with an active generic capture; its tracked staging path must be removed on
exit, and neither it nor its `.part` file may survive.

Finally reload, disable, and uninstall Wall-in-One with an internal child, an
external provider child, and an unrelated sentinel running. Only the plugin's
exact owned child may stop. The persisted still and Noctalia wallpaper surface
must remain intact.

The offline headless equivalent is
[`tests/vm/wall-in-one.nix`](../vm/wall-in-one.nix). Run it with
`nix build -L .#vm-test-wall-in-one` when that flake target is available.
