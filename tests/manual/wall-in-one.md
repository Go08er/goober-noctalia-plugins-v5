# Wall-in-One 0.7 manual test

Use the VM test or a genuinely separate nested Wayland/Noctalia session. A
fresh profile launched into the active desktop is not isolation: Noctalia's CLI
targets the active instance selected by its environment. Do not install optional
providers merely to make a capability card green.

**Safety gate before desktop testing:**

- give the nested session its own Wayland socket plus XDG config, data, cache,
  state, and runtime roots; use `plugins.auto_update = false` and a pinned local
  checkout, and carry that exact environment into every test/recovery command;
- select dedicated disposable image/video roots containing copies only, and
  never exercise deletion against real Workshop content or irreplaceable media;
- back up the isolated profile's Noctalia config and
  `plugins/data/goober/wall-in-one` directory before migration/failure tests;
- keep a separate TTY available. The normal recovery command is
  `noctalia msg plugins disable goober/wall-in-one` with the isolated session's
  exact environment; verify the target before using it;
- if Noctalia IPC itself is unavailable, terminate the isolated Noctalia test
  session you started. Do not use renderer-name matching or broad `pkill`
  commands against wallpaper processes.

Before testing any playlist or schedule, disable Noctalia's native wallpaper
slideshow/automation on every controlled output. Plugin API 17 has no public
pause or coordination command for that separate timer; leaving it enabled
creates a second wallpaper writer and invalidates transition results.
Disable every foreign wallpaper plugin/application on outputs used for
**internal** backend tests as well; `auto` intentionally prefers a detected
external owner.

## Install and customization

1. Import the repository through Noctalia's Git source flow and enable
   `goober/wall-in-one` from its catalog entry. Confirm all five services
   (`coordinator`, `renderer`, the thin `motionbgs` bridge, `palettes`, and
   `wallhaven`) start and the hub, shortcut, and
   `goober/wall-in-one:wall-in-one` widget load without undeclared-setting,
   glyph, or Luau errors. Do this once without installing the external
   `wall-in-one-motionbgs` program: only the MotionBGS page should be degraded,
   with **Open MotionBGS** and **Get helper** still available.
2. Add two widget placements. Give them different glyphs, labels, label
   visibility, and colors. Open Noctalia's native searchable icon selector from
   each placement, choose different icons, reload, and confirm each placement
   keeps its own choice.
3. Change the left, middle, and right gesture mappings in the hub. Exercise a
   native action, a provider panel, a capture action, a scheduler action, and
   **Open Wall-in-One**. Reload and confirm the schema-5 gesture map persists.
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

- `linux-wallpaperengine` receives the validated discovered project directory
  (or numeric Workshop-ID fallback), selected scaling/clamp, bounded
  FPS/audio/feature flags, the exact output, and the default `--layer bottom`;
- `mpvpaper` receives the exact absolute video and output, default
  `--layer bottom`, configured mute/hardware decoding, and `--auto-pause` when
  enabled. `--auto-mode <FULL|MAX|ACTIVE>` is passed only when the installed
  command advertises it; requesting `ACTIVE` without that capability fails
  closed. Treat auto-pause behavior as compositor-dependent;
- selecting **Background** passes `--layer background` to subsequent internal
  starts when the installed Wallpaper Engine build advertises `--layer`; a
  legacy build accepts only the default bottom path, and unknown layer values
  fail closed;
- pause, resume, toggle, replacement, and stop affect only the exact PID owned
  for that output;
- disconnecting an owned output, changing its effective backend, disabling the
  plugin, reloading its renderer service, or exiting Noctalia stops every owned
  child and removes that instance's FIFO/socket/log files;
- an unrelated long-running process and an external provider process keep the
  same PID throughout.

Run mpvpaper once with an empty disposable `XDG_CONFIG_HOME`, then repeat with
the user's normal mpv configuration. Ambient mpv scripts/options are outside a
Noctalia profile and must not silently change the clean-baseline result. Capture
the renderer status and private log immediately after any failure: replacement,
reload, and teardown may truncate or remove those diagnostic files.

Never accept `pgrep`, `pkill`, `killall`, name matching, detached sessions, or a
global mpv socket as ownership. The supervisor's private FIFO must be mode
`0600`, reject stale/non-monotonic nonces and malformed field counts, and keep
one bounded child/log per output.

With both renderer commands installed, start mpvpaper on one output and
Wallpaper Engine on another. Both exact children must coexist. Switch one
output from video to Wallpaper Engine and back: its old exact PID must exit
before the replacement is registered, while the other output and every foreign
process keep their PIDs. Do not accept same-output overlap as a hot-swap. Force
the replacement to fail and confirm the break-before-make path does not pretend
the old child resumed. An independently started foreign provider of the other
type remains outside Wall-in-One's same-output exclusion guarantee.
Also inspect the owned child's descendant process tree during each replacement;
no helper spawned by that owned renderer may survive after its parent is
stopped. Use a disposable video/scene that survives initial startup and exits
shortly afterward to verify that delayed crashes cannot create a rapid playlist
restart/advance loop.

Exercise the internal control matrix. mpvpaper must support stop,
pause/resume/toggle, mute/unmute/toggle-mute, and volume through its private mpv
socket. Wallpaper Engine must support stop and signal-based
pause/resume/toggle, while mute and volume are visibly unavailable. Commands
are one-shot: an acknowledgement timeout may report failure but must not replay
an apply, delete, or control action. Ordinary interaction should leave the
defensive 64-command renderer queue near empty, and heartbeat-only periods must
not republish unchanged status unless the heartbeat acknowledges a pending FIFO
write or reports recovery. Stop must forget the child; resume must work only
for a still-owned paused child, not silently relaunch a stopped source.

## Provider discovery and cooperative capture

With W Engine and mpvpaper fixtures enabled, open their panels and exercise
their documented service controls. The optional official Wallhaven panel may
also appear, but Wall-in-One's own Wallhaven browser must not depend on it. W
Engine capability/current state must come only from the versioned cooperative
adapter. Suppress its response, probe again, and confirm the lease expires
after the grace period.

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

In internal mode, test the separate native screenshot route with both an idle
output and an already running Workshop item. The exact command must include the
numeric item identity in status plus its validated absolute project directory
as `--bg` (or the numeric-ID fallback), output, configured `background` or
`bottom` layer, validated render options, a unique private
`staging/capture-*.png` path, `--screenshot`, and a one-to-five-frame internal
delay. Preserve the existing setting default 15 and range 1–120: a cooperative
adapter receives the full configured value, while the internal command clamps
it to linux-wallpaperengine's upstream maximum of five. Confirm one owned child
at a time: capture may sequentially replace Wall-in-One's live child, but must
never overlap it or touch a foreign provider process.

While a different Workshop or mpvpaper child is active, apply a new Workshop
whose native still is not cached. Wall-in-One should extract the new project's
source/preview fallback without stopping current playback, then replace the
renderer only after that still validates. Make the fallback fail and confirm
the previous child remains alive.

Accept a result only after the private PNG is non-empty and stable, validate it
through the normal atomic export path, and record
`linux-wallpaperengine-fbo-v1`. A successful capture of a previously running
item should restore that item only if the output, ID, backend generation, and
provider policy remain current. Force empty, partial, late, timed-out, and
cancelled results; each must clean staging and use only a valid source/preview
fallback. It must not claim that fallback is a rendered screenshot.

## Pairing, colors, and capture

1. Leave `capture_directory` empty and confirm the image root resolves to
   Noctalia's configured wallpaper directory (with `pluginDataDir()/captures`
   only as an API fallback). Manual exports go directly to that root; default-on
   automatic video/Workshop stills go to
   `Wall-in-One/Automatic Stills` with adjacent ownership sidecars. Then choose
   an absolute directory and confirm subsequent destinations follow it. A
   relative path, dot-segment path, or `/` must fail closed.
2. Export the public `wallpaper-get <output>` backing while all live-provider
   integrations are disabled. It should copy the validated image without
   pairing it back or accessing provider-private state.
3. Export a configured video at frame 0 and a later frame. Repeat in an isolated
   test environment whose `PATH` deliberately cannot resolve `ffmpeg`; do not
   uninstall or remove the host binary. Video/animated extraction must fail
   without changing the previous pair, while static signature validation
   remains usable.
4. Set **Configured manual pair file**, then run **Pair configured still** for a
   durable PNG/JPEG/WebP file and an animated GIF. The action must immediately
   validate and apply a standalone Noctalia backing on the selected output.
   WebP fallback validation must verify RIFF length/chunk structure, not just
   its magic bytes.
   AVIF must be decoder-validated and therefore fail closed when `ffmpeg` is
   unavailable. GIF pairing must persist a decoded PNG frame when `ffmpeg` is
   available and fail without
   changing the prior pair when it is not. A backing-only GIF export may remain
   GIF when no conversion is requested. A truncated or mislabeled image must
   be rejected. Temporary files must be beside the destination, use a
   non-image `.part` name, and be atomically promoted only after validation.
   Next apply a dynamic entry in **Automatic still** mode and confirm the
   configured manual image is not silently attached. To bind it, edit that
   entry and choose **Selected still** explicitly.
5. Pair different static representatives on two outputs through explicit
   selected-still entries. Confirm the private
   schema-6 `pairs` and `pair_registry` maps retain both mappings across reload.
   Reapplying an entry with **Automatic still** should reuse only its matching,
   fingerprint-validated dynamic pair. An entry with **Selected still** must
   use that exact file or fail visibly; it must never substitute an unrelated
   current output pair.
6. With automatic capture on (the default), remove the cached pair for a test
   video/Workshop source and confirm a validated still is generated before the
   renderer starts. Turn automatic capture off, clear the pair again, and use an
   entry with no selected still: it must fail with the still-required error and
   never start a renderer. Turning the toggle off must not delete an existing
   valid cached pair, and that cached pair may still be reused.
7. Remove or make a configured local video unreadable. With a valid selected or
   fingerprint-matched cached representative, applying it must stop the live
   layer, show that still, and retain a degraded warning naming the source.
   Without a valid representative it must block before the backing changes.
   Separately use valid media and a valid still with its renderer command
   unavailable and confirm the same visible degraded-live behavior.
8. Create a new entry in the playlist editor. Its initial policy must be the
   explicit adaptive wallpaper choice (`auto` and the first wallpaper generator,
   falling back to `m3-tonal-spot`), not a claimed snapshot of the current shell
   theme. Give entries policies for wallpaper-derived, built-in, community,
   custom, and inherited palettes in auto, dark, and light modes. Confirm the
   persisted bundle keeps the requested `{mode, source, selection}` tuple and
   the runtime status distinguishes requested policy from applied/fallback
   policy. Delete a custom palette or request an unavailable community palette
   and confirm the fallback is explicit rather than reported as verified
   success. Direct Quick Choice, library-add, and migrated compatibility entries
   must inherit unless the legacy color-sync setting requests the configured
   wallpaper generator.
9. For a pairing with a selected still, request an adaptive preview and verify
   the worker runs exactly
   `noctalia theme <image> --scheme <scheme> --both -o <file>`. It must not
   apply theme mode or color scheme. **Auto** must show both dark and light
   surface plus primary, secondary, tertiary, and error accents; explicit dark
   or light mode must select the matching result. An **Automatic still** pairing
   must show preview-unavailable until its validated capture exists. Repeat the
   same path/content/scheme and confirm the 16-entry memory cache avoids a
   second generator process. Rewrite different same-size content inside one
   timestamp tick and confirm SHA-256 forces regeneration. Change the source or
   scheme, force malformed or
   oversized output, and rapidly request A/B/C: errors must be visible, stale A
   must not replace C, only the latest pending request may run, and every
   private temporary JSON file must be removed.
10. Create reusable still, video, and Workshop pairings in their respective
    drawers. Drag cards into two playlists and drag occurrences to reorder them;
    then repeat using **Add to playlist** and explicit move-up/move-down buttons.
    Pointer drag/drop and button fallbacks must produce the same stable-ID
    result. Editing one catalog pairing must update linked occurrence snapshots.
    Deleting it must safely detach those occurrences by clearing `pairing_id`
    while preserving their last valid snapshots; it must not delete user media,
    selected stills, or the playlist occurrences themselves.
11. Confirm each apply is serialized: stop the old renderer, set the still via
   `wallpaper-set`, wait for its acknowledgement, set theme mode and color
   scheme, then start the dynamic renderer on a later update. A failed or stale
   step must not start the renderer or overwrite a newer generation.
12. Set `palette_output` and advance two outputs at the same instant. Only the
   configured connected leader may write Noctalia's global palette. Disconnect
   that output and confirm deterministic authority transfer and one reapply.
   With no configured leader, the sorted due-output batch must elect one writer
   instead of making every output race the global palette.
13. Refresh palette inventory twice inside its six-hour TTL. The second refresh
   should rescan local custom palettes without another community-network
   request. Corrupt the primary cache and confirm the bounded last-known-good
   backup is surfaced as degraded, not silently discarded.
14. Test both lock-screen configurations: a lock screen following the persisted
   wallpaper follows the pair; an explicit lock-screen image remains an
   external override and is never rewritten by this plugin.

Interrupt a capture and confirm no partial destination, stale staging file, or
`.part` file remains.

## Named playlists and schedules

Create two named playlists. Put a static-only entry, a local video, and a
numeric Workshop scene in the first; put one static-only entry in the second.
Use both `rotate` and `shuffle`, and test the explicit random navigation action.

1. Create, rename, duplicate, assign, and delete a playlist. Add, edit, reorder,
   apply, and remove entries through both drawer drag/drop and the button
   fallbacks. Entry IDs must remain stable when their order or labels change,
   and runtime `current_entry`, history, and shuffle bag must contain IDs rather
   than array indexes. Deleting an entry must remove only that ID from every
   affected run.
2. Apply the one-entry playlist. It must become parked after one successful
   apply with `running=false`, `paused=false`, and `next_due=0`; it must never
   wake every interval. Starting or resuming it again may reapply once but must
   return to the parked state.
3. Start, pause, resume, advance, go back, choose random, and stop the mixed
   playlist. The hub must accurately show running/paused/parked state, current
   entry ID, history, and next due time. While paused, next/previous/random must
   fail without changing the selection or renderer.
4. While a live entry is starting, immediately stop, advance, or change the
   backend. A late renderer acknowledgement must not revive the invalidated
   generation or overwrite a newer selection. Replacing a live child with a
   static-only entry must stop the exact old child before changing wallpaper.
5. Create an all-day schedule, a daytime schedule, and an overnight schedule
   with explicit month and weekday filters. Exercise a midnight interval that
   crosses both weekday and month boundaries. Reorder overlapping rules and
   confirm the lowest matching row wins; list position is the only precedence
   control. A manual apply pins the output until **Resume schedule** clears
   the pin. Schedule reevaluation must not replay every missed interval after
   sleep or downtime.
6. Assign the same playlist to two screens. Leave the first on playlist
   defaults and override rotate/shuffle plus time-per-swap on the second. The
   two runtime clocks and bags must follow their own effective settings even
   when a schedule changes the selected playlist. Restore **Playlist defaults**
   and confirm the screen immediately inherits playlist values again without
   rewriting that playlist or the other screen.
7. Trigger two displays on the same scheduler tick. Due outputs must be handled
   in stable connector order and only the elected palette authority may change
   the global Noctalia palette. The other display still receives its own still
   and dynamic renderer.
8. Seed a valid schema-3 playlist/output configuration and schema-6 runtime,
   then start schema 5. Migration must create reusable pairing records and
   occurrence links, expand every schedule without a month filter to all twelve
   months, and preserve the original schedule array as top-to-bottom precedence.
   With **start on load** off, definitions, stable IDs, history, schedule
   selection, and parked state survive but running playlists are disarmed.
   Enable **start on load** separately and confirm valid non-empty playlists are
   restored: a one-entry playlist applies once and parks. A multi-entry playlist
   with a valid current entry and a future saved deadline reapplies that entry
   without advancing, preserves the deadline, and then resumes its saved
   rotation. Invalid or overdue state follows the normal next-entry transition.
9. Remove entries and clear a playlist. Current entry/history/shuffle state must
   be normalized, an empty playlist must stop its exact owned renderer, and a
   deleted playlist must be removed from output fallback and schedule
   references without leaving an orphan run.

The video/Workshop library scan bounds candidate examination and performs
metadata/JSON work incrementally after each directory listing. After changing
a source directory or requesting refresh, allow update ticks to finish and
wait for `library.scanning=false`; do not treat an immediate partial list as
the completed inventory. The host `listDir` call itself may still materialize
the directory before those per-tick bounds apply, so include a very large
directory in exploratory responsiveness testing.

Choose separate image/video roots and then the same root for both. Supported
media must remain in the right still/video section, and a shared-root GIF must
appear only as video. Files directly in either root are user-owned and must
never offer deletion. Confirm marked `Wall-in-One/Wallhaven` and
`Wall-in-One/Automatic Stills` directories beneath the image root. Native
Wall-in-One downloads in the first require adjacent `.wallhaven.json`
provenance; files downloaded by another plugin remain user-owned. Generated
automatic stills require valid adjacent `.wall-in-one.json` sidecars.

Delete one Wall-in-One-managed MotionBGS video through the two-step hub action.
It must re-resolve the opaque library ID, require the direct managed directory
and valid sidecar, remove its own payload/metadata and its managed automatic
still, and leave a manually selected still untouched. Tamper with the sidecar,
move a managed file into a nested/user directory, reuse a stale item ID, delete
the file externally, and unsubscribe only a disposable test Workshop item that
can be restored; every case must fail closed or merely disappear on refresh,
never trigger speculative cleanup.

## Wallhaven API provider

Use an offline HTTP fixture first. Live Wallhaven testing is optional and must
respect the provider's request interval.

1. Search with general/anime/people category masks, purity masks, sorting,
   order, minimum resolution, ratios, color, and page. Invalid masks, ratios,
   colors, resolutions, pages, or control characters must fail locally. NSFW
   purity must require a configured API key.
2. Confirm the API key is sent only as `X-API-Key`, never in a URL, log,
   coordinator status, or result item. Redirects and insecure TLS must remain
   disabled. Search and detail responses are capped before JSON decoding and at
   most 24 normalized results are published.
3. Request details only for an ID in the current result set. Reject mismatched
   IDs, unsupported CDN hosts, mismatched MIME/extensions, and stale command
   nonces. A second operation while one is active must report busy rather than
   silently replacing it; clear may invalidate the result set.
4. Download a selected PNG and JPEG. The coordinator, not the panel request,
   must derive `Wall-in-One/Wallhaven/wallhaven-<id>.<ext>` and the exact
   nonce-bound staging path. Confirm the 64 MiB ceiling, advertised-size and
   image-signature validation, no-overwrite behavior, atomic promotion, and an
   adjacent `.wallhaven.json` record containing provider, ID, source page,
   bytes, and timestamp.
5. Make sidecar promotion fail after image promotion. No untracked image may
   remain. Tamper with provenance and confirm the library treats the payload as
   user-owned/non-deletable. A valid managed item may be removed only through a
   fresh opaque library ID; deletion must remove its exact playlist references
   and any owned automatic still while preserving selected user stills.
6. Disable or break the native API service and test without the optional
   official Wallhaven plugin. **Open wallhaven.cc** must still launch
   `https://wallhaven.cc/` through the desktop URL opener. If no opener exists,
   report that limitation visibly; API, parser, authentication, or panel
   availability must never remove the direct-site fallback.

## MotionBGS external helper

MotionBGS exposes public pages rather than a stable API. Its HTTP, parser,
cache, and download work now belongs to the separately installed one-shot
Python 3.11+ program, not Noctalia's Luau service. Begin with the offline helper
and VM fixtures; live-site behavior is exploratory.

1. With the helper absent, confirm only MotionBGS search/download is degraded.
   The page must explain the missing binary and retain working **Open
   MotionBGS** and **Get helper** buttons. Wallhaven, local libraries,
   playlists, palettes, Workshop discovery, and renderer controls must remain
   unchanged.
2. Obtain `motionbgs-helper/wall-in-one-motionbgs` through the **Get helper**
   link. First install it as the exact executable name
   `wall-in-one-motionbgs` on the isolated session's `PATH`, mark it executable,
   leave the advanced path setting empty, and request a reprobe. Then remove it
   from that test PATH, select its absolute executable with **MotionBGS helper
   program**, and reprobe again. Relative paths, a directory, a renamed
   arbitrary command, malformed probe output, or incompatible capabilities must
   fail closed for MotionBGS only.
3. Capture one successful `WIO-MBGS-PROBE1` schema-1 probe and one
   `WIO-MBGS-RPC1` schema-1 operation. Confirm each action starts a fresh process
   and exits; requests never exceed 8 KiB, responses never exceed 128 KiB, and
   transport files are private regular files beneath
   `pluginDataDir()/motionbgs-bridge-v1/cache/rpc`. Cache data must stay beneath
   `pluginDataDir()/motionbgs-bridge-v1/cache`; the retired in-process cache
   location must not be restored or reused.
4. Search a fixture containing same-origin cards, thumbnails, and numeric media
   IDs. Result count must obey the configured 1–48 bound. Open details
   containing same-origin HD/4K `/dl/<quality>/<id>/` links, then repeat the
   request inside the cache TTL and confirm the one-shot program performs no
   second HTTP fetch.
5. Feed an anti-bot challenge, unknown markup, cross-origin or mismatched
   effective URL, unsafe path, oversized response, invalid MIME/signature pair,
   and malformed RPC output. Each must fail closed with a bounded diagnostic.
   Confirm ambient curl configuration is disabled, redirects never leave the
   strict origin allowlist, and no browser automation or challenge bypass is
   attempted.
6. Download the local MP4 fixture. Confirm bounded size/time plus the file-size
   backstop, MP4 MIME/signature agreement, atomic no-replace install, and the
   adjacent `.motionbgs.json` provenance sidecar. The destination is the marked
   `Wall-in-One/MotionBGS` child beneath `video_directory`, not the user-owned
   root itself. The response must retain `cached`, `source_url`, `fetched_at`,
   the complete selected detail record, and the download receipt.
7. Test clear, monotonic command nonces, bounded queueing, serialized network
   starts, result/status mirroring in the coordinator, and the direct website
   fallback. Clear, disable, or reprobe during an in-flight fixture request and
   confirm its late completion cannot publish success/results, install media,
   or leak request/response/temporary files. A search/detail cache write that
   atomically committed just before guard revocation may remain as harmless
   metadata; clear once more when an empty metadata cache is the desired final
   state.

Live-site behavior is exploratory because site markup can change. Do not make a
release depend on a successful public-network request.

## Storage and failure recovery

After several mappings, pairings, playlist edits, and schedules, inspect plugin
data:

- `config.json` is schema 5 and contains `gestures`, item-profile `pairings`
  plumbing, named `playlists`, per-display engines, and per-output fallback/Quick
  Choice, playback override, and list-ordered month/weekday schedule
  configuration;
- every item profile is a stable-ID media/still/theme bundle. Every playlist
  occurrence has its own stable entry ID, a validated bundle snapshot, and an
  optional `pairing_id` link; detaching a deleted catalog item preserves that
  snapshot;
- `runtime.json` is schema 6 and contains private `pairs`/`pair_registry`, runs
  keyed by output and playlist ID, output selection/pin/schedule state, palette
  request/application state, and bounded active `current_workshops`;
- coordinator lifecycle status is protocol 4 and remains small. It advertises
  revisioned config, runtime, and library domains; the panel reconstructs its
  detailed view from matching-instance domain snapshots and the provider-owned
  renderer/catalog states. Neither the lifecycle object nor the panel view may
  republish retired `reels` or `cycles`; private `pair_registry` data remains
  only in validated persisted runtime and must not be published into a shared
  state domain;
- an exact running or paused internal W Engine child publishes its numeric ID in
  `current_workshops`, while capture, stop, exit, ownership loss, or teardown
  removes it rather than preserving stale active state;
- valid schema-1/2/3 config and schema-1/2/3/4/5 runtime fixtures migrate once
  without losing mappings, pairs, current selection, history, or shuffle bag.
  The explicit schema-3 fixture must gain reusable pairing links, all-month
  schedule filters, and list-order precedence. Legacy numeric indexes become
  stable entry IDs, and a migrated one-entry run is parked rather than armed;
- migration stages both documents, writes a transaction marker, and recovers
  config/runtime together after simulated interruption. A second successful
  write rotates both prior valid documents into `.bak`; no `.next`, `.tmp`, or
  stale transaction marker remains;
- corrupt or future-schema JSON is preserved as evidence, diagnostics explain
  the problem, and mutating actions fail closed rather than recreating defaults.

Both documents have an 8 MiB read/write ceiling. Exercise over-limit config and
runtime files plus malformed nested maps: more than 64 outputs, more than 1024
catalog pairings or dynamic pairs, overlong paths/keys, nonnumeric or oversized
current Workshop IDs, too many playlists/runs/schedules, duplicate entry IDs, stale IDs in
history/shuffle bags, and invalid nested pair/run/capture/palette records must
all fail closed without overwriting the evidence. At the limits, successful
writes must prune oldest pair-map entries deterministically rather than growing
without bound.

Before startup, place more than 512 files in `pluginDataDir()/staging`, mixing
Wall-in-One `capture-<safe-id>.png` names with unrelated names and extensions.
Startup cleanup must inspect at most its bounded batch and remove only its own
matching staging files. Exit during adapter, native, and queued captures and
confirm their known staging paths are removed without touching unrelated
files. Repeat with an active generic capture; its tracked staging path must be
removed on exit, and neither it nor its `.part` file may survive.

Finally reload, disable, and uninstall Wall-in-One with an internal child, an
external provider child, and an unrelated sentinel running. Only the plugin's
exact owned child may stop. The persisted still and Noctalia wallpaper surface
must remain intact.

The offline headless equivalent is
[`tests/vm/wall-in-one.nix`](../vm/wall-in-one.nix). Run it with
`nix build -L path:.#vm-test-wall-in-one`. The current schema-5/runtime-6,
palette, native-Wallhaven, external-MotionBGS bridge/helper, and named-playlist
tree are covered by that full integration VM. Repeat it after any code or
harness change before using this checklist on a disposable live profile; the VM
does not certify real GPU, audio, lock-screen, compositor-layer, or shell-theme
behavior. In particular, mpvpaper is not installed on the current host, so this
record makes no live internal-video playback claim.
