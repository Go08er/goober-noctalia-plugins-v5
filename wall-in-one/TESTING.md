# Wall-in-One test record

Wall-in-One `0.8.0` is tested as one owned wallpaper stack: routed UI, provider
services, persisted item-profile/playback state, and exact renderer children.
Tests must not require another wallpaper plugin, private state, or cross-plugin
IPC.

## Automated checks

Run from the repository root:

```bash
noctalia plugins lint wall-in-one
python3 tools/validate.py --require-shellcheck
python3 wall-in-one/tests/test_contract.py
bash wall-in-one/scripts/backend-provider self-test
bash wall-in-one/scripts/motionbgs-provider self-test
bash wall-in-one/scripts/provider-thumbnail self-test
./wall-in-one-backend/wall-in-one-backend self-test
python3 -m unittest discover -s wall-in-one-backend/tests -p 'test_*.py' -v
nix build -L path:.#vm-test-wall-in-one
```

The offline contract checks manifest/state schemas, translations, backend
self-tests, bounded files and provider routes, exact renderer argv/PID cleanup,
root ownership, migration, and source-level Luau invariants. The standalone
backend self-test checks generic capability and MotionBGS URL/parser invariants.
Its unittest suite exercises library/palette paging, provider parsing, preview
cache, protocol, and install boundaries without network access. The VM compiles
and loads all six
services, including the generic backend and thin MotionBGS bridges, plus the
real panel; it exercises state commands against disposable fixtures and rejects
callback CPU-budget errors.

## Routed panel contract

Assert the `hub` panel is a 1160 × 780 floating surface (centered, not opened
near the click). No test should expect a standalone window: API 17 has no window
entry or page-stack primitive.

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
Invoke Customize on a fresh Workshop card with no customized profile and assert
that the synthesized automatic-still bundle opens the editor. The callback must
not resolve a presentation namespace as a global; retain the generic
use-before-local-namespace contract check.

For a dynamic customization, require the selected-still control to page only
indexed user-owned and Wallhaven images, retain an explicit manual-path escape
hatch, and request automatic representative preparation through the
coordinator. The dedicated capture may populate the cache registry and library,
but must not mutate the applied per-output pair, wallpaper, palette, or
renderer.

Open an existing playlist occurrence's editor and require a library-first
source picker with separate still, video, and Workshop tabs. Each tab must
materialize at most six cards per page, including preview and palette swatch,
and the editor must expose no raw source-media path or Workshop-ID input. A
dynamic occurrence must reuse the six-card still-library picker; only its
collapsed manual representative-still escape hatch may accept an absolute path.
Rebind an occurrence to a different medium and verify that its stable entry ID,
list position, and insertion timestamp are preserved. Its representative and
palette edits must update the selected medium's shared item profile and every
linked occurrence, rather than becoming an isolated occurrence override or
rewriting the old medium's profile.
Switch playlists while that editor is open and verify the draft closes rather
than targeting an equal entry ID in another playlist. The VM panel probe must
invoke the production open/select/render path with a real indexed card, preserve
the originating playlist and absolute position, and reject watchdog log records.
The state watcher may only queue a fixed scalar projection; normalization and
persistence must occur from the ordinary coordinator update callback.

Navigate into MotionBGS with a 36-result fixture and a full preview backlog.
Render the production route as three fixed 12-card local pages, drive sustained
frame callbacks, and prove that frames advance only bounded drag and
still-choice, Workshop-index, and palette-index reconciliation. Preview
synchronization and full `panel.render` tree construction belong only to
`update()`. Drive the Wallhaven navigation callback through the same panel. The
journal must contain no panel callback CPU-budget overrun or timeout-disable
sequence.

## Explicit roots and storage gating

Test empty, nonexistent, separate, and identical image/video roots. Wall-in-One
must never substitute Noctalia's wallpaper directory, copy one root into the
other, or create the selected root.

- With no image root, do not scan images, create image managed children, run a
  Wallhaven download, export a still, or start automatic capture.
- With no video root, do not scan videos, initialize the MotionBGS bridge cache,
  launch its external program, create its managed child, or download video.
- A missing root must not prevent the other root's independent library from
  working.
- Home is setup-first while either root is unavailable. Provider/Steam direct
  links remain usable.

After selecting existing roots, assert these exact derived locations:

- `<image root>/Wall-in-One/Wallhaven`;
- `<image root>/Wall-in-One/Automatic Stills`; and
- `<video root>/Wall-in-One/MotionBGS`.

Each Library medium page must report its selected root, derived directories,
relevant defaults, and private `pluginDataDir()` cache locations. MotionBGS must
report `pluginDataDir()/motionbgs-bridge-v1/cache`, not the retired in-process
cache location. Direct-root files are user-owned.
Managed deletion requires a direct child, expected marker, matching adjacent
sidecar, and a current opaque library ID. Path substitution, nested paths,
tampered sidecars, and stale IDs fail closed.

## External backend

Test the three-tier binary resolution order: a readable absolute
`backend_binary_path` override; the regular-file
`pluginDataDir()/backend-path` pointer; then the exact `wall-in-one-backend`
name on PATH. The pointer must contain exactly one bounded absolute path line,
with an optional terminal LF. The documented installer must publish it as a
regular non-symlink file beneath the plugin data directory. Its target must be
a non-empty, regular, non-symlink executable before a launcher accepts it.
Reject relative paths, directories, symlinks, control characters, extra lines,
arbitrary shell commands, malformed probe output, incompatible schemas, and a
probe missing any of `library.scan`, `palettes.inventory`, `preview.sync`, or
the four `wallhaven.*` actions. A valid explicit setting must override a valid
pointer, and a valid pointer must override PATH.

Exercise automatic first-install discovery without restarting or reloading
Noctalia: begin with no backend, atomically rename a valid pointer into place,
and require the generic service plus isolated provider bridges to become ready
within the bounded missing-state retry interval. Once a compatible backend is
ready it must not be process-probed forever merely to detect optional manual
pointer replacement; replacement/removal is adopted on service/config reload.

The thin MotionBGS bridge must prefer the same explicit setting and automatic
pointer as the generic bridge. Its compatibility-only third tier is the
invisible retired `motionbgs_binary_path`, followed by the fixed PATH name. A
unified target uses `motionbgs-probe` and `motionbgs-rpc`; a legacy standalone
helper uses `probe` and `rpc`. The retired setting must never select the generic
backend used by library, palette, preview, or Wallhaven operations. Exercise
unified and legacy launch/cancellation, plus automatic adoption of a newly
installed shared pointer while the legacy bridge is active.

Pin the Home setup card to the documented three-command flow: full commit
`4b226a8b2fa8ad41aae1245dcc8e6bfa2bf1c391`, SHA-256
`49a5f9ef0248779492849ca6378853dbc0fba3350d4fd360ee9425fb1101703a` verified
against the value pinned in the plugin rather than a downloaded `.sha256`,
quoted paths, verification before `chmod`, the `pluginDataDir()/backend-path`
pointer, and `self-test` as the final step. The card may write that pointer
itself and may hand the commands to the user's terminal or clipboard; it must
never run the download, checksum, permission, or self-test steps silently in
the background. A rejected or absent terminal must say so rather than appear to
succeed, and an install directory that does not exist yet must be created.
Confirm both paths end with a resolved backend: the in-panel install, and the
copied block pasted into an unrelated directory, which must write its own
pointer from `$PWD`.

Pin `WIO-BACKEND-PROBE1` and `WIO-BACKEND-RPC1` interface schema 1. Requests are
at most 64 KiB and the manifest plus each page are at most 128 KiB. Transport
files must be current-user-owned, regular, non-symlink direct children of their
fixed private transport. Remove the exact guard while a request waits for its
private `flock` or is active; no operation may publish a response, partial
inventory, preview, or downloaded media after cancellation.

Build fixtures containing user images/videos, managed Wallhaven/MotionBGS
media, automatic stills, valid and tampered sidecars, shared image/video roots,
and multiple Workshop roots. Assert non-recursive discovery, GIF de-duplication
for a shared root, stable IDs, ownership/deletion fields, representative lookup,
case-insensitive sorting, hard candidate/item limits, and fixed 12-record page
files. The Luau bridge must validate those pages in bounded update batches and
publish one complete replacement only after every page passes.

Exercise `palettes.inventory` with valid/invalid custom JSON, fresh/stale/corrupt
community cache and backup, a bounded offline catalog response, pagination, and
cancellation. Cover both a symlinked custom-palette directory and a symlinked
JSON entry, including a root-owned Nix-store-style target; they must pass only
through the palette inventory's stable, bounded read-only descriptor path. A
FIFO or changing/non-regular target must fail without blocking. Confirm that
transport, cache, response, marker, download, and media paths continue to reject
symlinks. Exercise `preview.sync` with 36 provider results, cache hits,
one-at-a-time misses, LRU pruning, corrupt/oversized manifests, invalid URLs,
and cancellation. Stable cache roots are `pluginDataDir()/palettes-cache.json`
plus `.bak` and `pluginDataDir()/provider-previews/v1`; temporary library and
palette pages are direct children of `pluginDataDir()/backend-bridge-v1/rpc`.

With the backend absent, refresh must fail visibly without clearing the last
complete library or palette inventory. Provider previews and integrated
Wallhaven/MotionBGS actions degrade, but configured playlists, renderer control,
Noctalia wallpaper/palette application, adaptive palette preview, and direct
site links remain usable. The plugin must never download or chmod the backend
itself.

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
download, and clear. Pin 128 KiB/24-result responses, two-second request spacing,
64 MiB image limit, documented origins, redirects disabled, and private-header
API authentication.

A successful download must atomically leave both the managed JPG/PNG and exact
`.wallhaven.json` sidecar. Content-type/signature/size mismatch, overwrite,
interruption, or sidecar promotion failure leaves no managed file.

The result card itself must expose available/downloading/already-on-disk state
using `active_id` plus the indexed managed library. An already-installed ID is
not submitted again; no selected-item hero or scroll-to-top download step is
required.

## MotionBGS provider

Pin the existing schema-1 command/ack/status/result keys and
search/details/download/clear actions. The Luau service must remain a bridge:
no `update()` callback, HTTP implementation, HTML selectors, provider cache
parser, or download transport may return to `motionbgs.luau`. Exercise several
large cold external parses and reject every Noctalia callback CPU-budget error;
the work must occur in the one-shot process rather than being spread across
service ticks.

Require `active_slug`, `active_quality`, and a queue-bounded
`queued_downloads` projection. Result cards expose HD and 4K actions inline,
show queued/active/on-disk state, reject an exact active or pending duplicate,
and keep a persistent queue summary visible while work remains. Do not assert a
byte percentage because the one-shot helper protocol does not stream one.

Test MotionBGS discovery through the explicit `backend_binary_path`, automatic
pointer, compatibility-only `motionbgs_binary_path`, and fixed
`wall-in-one-backend` PATH tiers in that order. Verify unified and legacy
command names independently. Reject relative paths, directories, control
characters, arbitrary command strings, missing executables, malformed
compatibility-probe output, incompatible schema, and incomplete capabilities.
A missing or incompatible generic backend must degrade Wallhaven, provider
previews, and fresh library/external palette inventory; MotionBGS may remain
available through a valid legacy helper. Configured playlists, adaptive palette
preview, renderers, and direct-site/**Get backend** actions remain available.

Pin `WIO-MBGS-PROBE1` and `WIO-MBGS-RPC1` interface schema 1. The probe must
advertise exactly search/details/download/clear. RPC request files are capped at
8 KiB and response files at 128 KiB, use owned regular no-symlink paths beneath
`pluginDataDir()/motionbgs-bridge-v1/cache/rpc`, and are removed on success,
error, cancellation, reload, and exit. The external cache belongs beneath
`pluginDataDir()/motionbgs-bridge-v1/cache`; neither bridge nor helper may
restore the retired in-process cache location.

Each request must carry the same unique cancellation-guard path passed on the
helper command line. Remove the guard while an RPC is waiting for the lock and
while a fake media transfer is active; both must stop without a response or
installed pair. Exercise the 30-second non-download and 75-second download
helper deadlines under the bridge's 40/80-second process timeouts.

The download response must include `cached`, `source_url`, `fetched_at`, the
full normalized `selected` detail object, and `download`. Reject a response that
omits, truncates, or contradicts those fields before publishing results or
managed-download status.

Keep the launcher as a protocol/resource gate. Assert exact executable
resolution, private transport output, sanitized Python environment, bounded
single-line completion records, cancellation, and `ulimit -f` backstops. A
one-shot program must exit after each probe or RPC; no helper daemon or updater
is installed, launched, or supervised by the plugin.

Run the standalone program against offline fixtures covering 80-byte queries,
1–48 results, one-second network spacing, one-MiB HTML, bounded parser
tags/attributes, three same-origin redirects, unpaged text search, pageable
latest/genre/tag/4K, first-page-only HD, explicit empty results, changed markup,
challenge pages, and exact `/search?q=night` to `/tag:night/`
canonicalization. Reject `/tag:nature/`, malformed paths, cross-origin
destinations, and any curl effective URL that differs from the requested hop.

Transport tests must disable ambient curl configuration and preserve the strict
origin allowlist. Cross-check HTML and MP4 MIME types with signatures, enforce
the 16–512 MiB MP4 bound, accept only numeric HD/4K download IDs, and require
atomic no-replace MP4 plus `.motionbgs.json` sidecar installation. Cover bounded
cache restore/clear, lock serialization, interruption, cancellation, conflict,
and temporary-file cleanup. Do not execute third-party JavaScript, bypass a
challenge, or automate repeated live requests.

Also pin explicit `:443` canonicalization and final download identity: a
same-origin redirect may resolve to the selected ID's MP4, but a different ID,
query-bearing route, or mismatched curl effective URL must fail before install.

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
removed. Drag/drop and the **Add to playlist** button must produce identical
bounded add commands; occurrence reordering remains drag-only. Drag payloads
never carry trusted paths or deletion authority.

Exercise the VM `playlist_replace_entry` fixture after playlist placement. It
must rebind the selected occurrence to the fixture Workshop medium while
preserving the occurrence ID, array position, and `added_at`; it must leave the
old medium's profile intact and synchronize the selected Workshop profile's
shared representative/palette snapshot.

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
palette leader. The host CLI and source hashing remain Luau-owned; inventory
discovery is backend-owned. Missing community/custom choices preserve intent and
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
