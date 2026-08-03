# Wall-in-One test record

Wall-in-One `0.6.0` is tested as one owned wallpaper stack: routed UI, provider
services, persisted item-profile/playback state, and exact renderer children.
Tests must not require another wallpaper plugin, private state, or cross-plugin
IPC.

## Automated checks

Run from the repository root:

```bash
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
nix build -L path:.#vm-test-wall-in-one
```

The offline contract checks manifest/state schemas, translations, shell-helper
self-tests, bounded files and provider routes, exact renderer argv/PID cleanup,
root ownership, migration, and source-level Luau invariants. The VM compiles and
loads all five services plus the real panel, exercises state commands against
disposable fixtures, and rejects callback CPU-budget errors.

## Routed panel contract

Assert the `hub` panel is full-size floating (`fill` × `fill`, centered, not
opened near the click). No test should expect a standalone window: API 17 has no
window entry or page-stack primitive.

Open the panel and traverse exactly these local routes:

- Home;
- each detected display nested beneath Home, opening one combined page for its
  renderer controls, rotate/shuffle and interval policy, pinned default
  playlist, draggable scheduled overrides, and engine settings;
- Library → Images / Videos / Wallpaper Engine;
- Shops → Wallhaven / MotionBGS / Steam Workshop;
- Playlists → each named playlist; and
- Diagnostics.

Verify that selecting one route replaces the content view instead of stacking
shop, library, renderer, and playlist controls together. Repeated navigation
must not duplicate preview tasks, provider commands, editors, or drag payloads.
The normal panel must retain select controls; do not convert it to a persistent
panel merely to keep it beside another panel.

Library cards should render a bounded still thumbnail in a consistent grid. A
static defaults to itself; video/Workshop uses a valid preview or automatic
still; all three get an implicit adaptive wallpaper theme policy and can be
applied or added without first creating a profile. Optional Customize, Reset to
defaults, and sidecar-gated managed-media deletion remain distinct compact
actions. Reset and managed deletion require two-step destructive confirmation.

## Explicit roots and storage gating

Test empty, nonexistent, separate, and identical image/video roots. Wall-in-One
must never substitute Noctalia's wallpaper directory, copy one root into the
other, or create the selected root.

- With no image root, do not scan images, create image managed children, run a
  Wallhaven download, export a still, or start automatic capture.
- With no video root, do not scan videos, initialize MotionBGS metadata/network
  work, create its managed child, or download video.
- A missing root must not prevent the other root's independent library from
  working.
- Home is setup-first while either root is unavailable. Provider/Steam direct
  links remain usable.

After selecting existing roots, assert these exact derived locations:

- `<image root>/Wall-in-One/Wallhaven`;
- `<image root>/Wall-in-One/Automatic Stills`; and
- `<video root>/Wall-in-One/MotionBGS`.

Each Library medium page must report its selected root, derived directories,
relevant defaults, and private `pluginDataDir()` cache locations. Direct-root files are user-owned.
Managed deletion requires a direct child, expected marker, matching adjacent
sidecar, and a current opaque library ID. Path substitution, nested paths,
tampered sidecars, and stale IDs fail closed.

## Per-display engine settings

For two outputs, save different `outputs[output].engines` objects and reload.
Assert one display's edit never changes the other:

- `layer`: `bottom` or `background`;
- video: enabled, mute, hardware decode, auto-pause,
  `FULL`/`MAX`/`ACTIVE`, bounded options; and
- Workshop: enabled, FPS 5–144, volume 0–100, silent,
  `default|stretch|fit|fill`, `clamp|border|repeat`, and all validated flags.

Reject malformed types, control characters, out-of-range values, unknown
enums, and simultaneous `no_fullscreen_pause` plus
`fullscreen_pause_only_active`. Migrate schema 1–4 outputs with documented
schema-5 engine defaults, then persist only the per-display object; do not read
removed manifest settings. Legacy actions must normalize to equivalent owned
playback/playlist actions or no action; they must not invoke a separate service.

## Renderer ownership and lifecycle

Use fake foreground `mpvpaper` and `linux-wallpaperengine` commands. Assert:

- one dynamic exact child per display and coexistence across displays;
- break-before-make replacement in both directions;
- a failed replacement does not resurrect the previous child;
- stop, stop-all, hotplug, reload, disable, and exit drain owned descendants and
  the private FIFO;
- no `pgrep`, `pkill`, detached scope, or unrelated PID file; and
- stale/replayed nonces, malformed fields, and injected paths/options fail.

mpvpaper argv must include the selected layer, validated auto-pause mode, and
one literal options argument; `ACTIVE` is allowed only when advertised. Exercise
private-socket pause and audio controls plus exact-PID signal fallback.
Wallpaper Engine receives the validated local project directory, layer,
scaling/clamp/FPS/volume/flags, and rejects unsupported `background` or runtime
audio operations.

Make a child pass startup and then exit. An armed multi-entry playlist must use
the 10/20/40/80/160/300-second recovery sequence, reset only after 60 seconds
stable, and clear on explicit display/playlist intent.

For capture, require a unique `pluginDataDir()/staging/capture-*.png`, exact
output/project/layer/settings, `--screenshot`, and delay 1–5. Accept only a
non-empty stable artifact closed by the child. Verify atomic promotion,
`linux-wallpaperengine-fbo-v1` provenance, still-current restoration, and stale
callback rejection after stop, hotplug, settings change, reload, or superseding
apply.

## Wallhaven provider

Offline fixtures cover query, category/purity masks, sort/order/top range,
minimum/exact resolution, ratio, color, page, stable random seed, detail,
download, and clear. Pin 512 KiB/24-result responses, two-second request spacing,
64 MiB image limit, documented origins, redirects disabled, and private-header
API authentication.

A successful download must atomically leave both the managed JPG/PNG and exact
`.wallhaven.json` sidecar. Content-type/signature/size mismatch, overwrite,
interruption, or sidecar promotion failure leaves no managed file.

## MotionBGS provider

Pin schema-1 command/ack/status/result keys; search/details/download/clear;
80-byte query, 1–48 results, queue eight, one-second request spacing, one-MiB
HTML, three redirects, and 16–512 MiB MP4 bounds.

The parser must preserve one anchor per callback, switch to 16ms only while
parser state is active, and restore 250ms on success, parse error, cancellation,
configuration disable, launch refusal, and exit. Use the live-like listing with
355 irrelevant anchors plus 36 cards (391 anchors total). Including EOF and
publication, 393 callbacks take about 6.3 seconds and must remain at or below
seven seconds; the 250ms cadence would take about 98 seconds. Repeat at least
three large cold parses and reject any Noctalia CPU-budget error.

Assert listing metadata performs exactly one pass over `<link>` elements in only
the first 16 KiB of the document, stops after 32 links, and derives the total
hint from that same prefix. Reject a return to full-document pagination passes;
that work previously exceeded Noctalia's 25 ms callback deadline after card
parsing.

Test `/search?q=night` with effective URL `/tag:night/` as accepted. Reject
`/tag:nature/`, malformed/cross-origin destinations, and canonical tags that do
not exactly equal the lowercased space-to-hyphen query. Restore a cached search
only through the same route validator.

Fixtures also cover unpaged text search; pageable latest, genre/tag, and 4K;
first-page-only HD; explicit empty results; changed markup; challenge pages;
strict image origins; numeric HD/4K download IDs; `ftyp`; atomic MP4 and
`.motionbgs.json`; cancellation; and no temporary-file leaks. Do not execute
third-party JavaScript or automate repeated live requests.

An optional live smoke test may make one ordinary search, one detail request,
and one small download through the panel. Stop on a challenge or changed access
policy. Confirm the video lands beneath the selected video root and remains a
normal local-library item without the network afterward.

## Item profiles, palettes, playlists, and schedules

For static, video, and Workshop library cards, verify the default selected or
automatic still and adaptive palette while the default color toggle is enabled;
with it disabled, verify that an uncustomized item keeps the current theme. A
live apply must persist the still before theme IPC and before renderer start.
Missing media may degrade to a validated representative; without one it must
fail before changing playback.

Apply and add one default item of each kind without an up-front create step.
Customize one item of each kind and assert its schema-5 `pairings` plumbing
records `customized = true`; the source identity must remain read-only, and
linked occurrences in two playlists must retain stable entry IDs and receive
the edited validated snapshot. Reset the item and
assert the same profile ID is rewritten with derived defaults and
`customized = false`, with linked snapshots synchronized. Then exercise
the same default medium/source with a different palette and assert the original
profile is reused, every linked snapshot is refreshed, and duplicate records
are not created. Remove a source from the indexed library and verify that it no
longer produces an orphan Library card; an existing playlist snapshot remains
visibly marked missing until the source is restored or that occurrence is
removed. Drag/drop and explicit buttons must produce identical bounded
commands; drag payloads never carry trusted paths or deletion authority.

Test named playlist create/rename/duplicate/delete, stable-ID reorder, rotate,
shuffle bag, start/pause/resume/stop/next/previous/random, Quick Choice, and
one-entry parking. Assign one playlist to two displays and verify independent
cursor, history, due time, engine settings, and manual pin.

The display's visual playlist library must support dropping onto the fixed row-1
default and between scheduled rows. Schedule rules use visible order,
month/weekday sets, all-day or bounded time, and overnight prior-date semantics;
the lowest matching row wins. Test insertion, reorder, DST/time changes, resume
schedule, and no burst replay of missed swaps.

Palette previews use a real validated still, exact non-applying Noctalia theme
CLI, SHA-256-aware bounded caching, stale callback rejection, and one global
palette leader. Missing community/custom choices preserve requested intent and
report the visible fallback.

## Persistence and manual desktop boundary

Validate `config.json` schema 5 and `runtime.json` schema 6, 8-MiB caps, bounded
collections, coordinated journal/backup migration, and fail-closed future or
corrupt schemas. Interrupt every migration rename stage and require a complete
new pair or complete rollback.

The VM cannot prove compositor visuals. On a disposable Wayland session, test
both layers, hotplug a second display, run different engines concurrently,
inspect a captured PNG, exercise playback/audio capability gating, and reload
or disable while confirming no owned renderer remains and the last static
backing/theme is retained.
