# Wall-in-One provider and renderer architecture

Wall-in-One `0.8.0` has four integration boundaries: Noctalia's public wallpaper
and theme APIs, provider services shipped by Wall-in-One, the separately
installed one-shot backend program, and dynamic wallpaper processes started and
supervised by Wall-in-One. It does not discover, open, signal, or exchange state
with separate wallpaper extensions. The external backend performs bounded bulk
computation; it is not a renderer or long-lived plugin service.

## Routed panel

Noctalia plugins cannot create independent application windows. Wall-in-One
therefore uses one normal panel configured as a roomy floating view
(`width = 1160`, `height = 780`). Its hierarchy is local Luau route state,
not a collection of simultaneously rendered sections:

- **Home** — readiness, setup, and concise status, followed by one inset route
  per detected display;
- each display route — one combined page containing a visual playlist library,
  renderer controls, rotate/shuffle and interval policy, one ordered
  default-plus-schedule priority list, and per-display video/Workshop engine
  settings;
- **Library** → **Images**, **Videos**, **Wallpaper Engine**;
- **Shops** → **Wallhaven**, **MotionBGS**, **Steam Workshop**;
- **Playlists** → each named playlist; and
- **Diagnostics**.

Selecting a route renders only that page. The nested navigation is implemented
inside the panel because API 17 has no native page-stack, tab, drawer, or
standalone-window primitive. A normal panel is used instead of a persistent
panel so ordinary controls, including selects, remain available.

Library cards use a still image as their visual identity. A static image selects
itself as its still. A video or Workshop project uses a validated selected
preview when one exists and otherwise defaults to automatic still generation.
Every card synthesizes a complete default item profile, using adaptive wallpaper
colors by default or keep-current when that installation-wide default is
disabled. Applying or adding it to a playlist never requires a separate create
step. Customization is optional. Apply, playlist add, drag/drop, and customize
all pass through the same validated bundle boundary.

The customization editor replaces its ordinary raw still-path field with a
fixed six-card page over indexed user-owned and Wallhaven stills. Only the
selected page is materialized; a collapsed manual-path escape hatch remains for
a representative still outside the index. Opening an automatic video/Workshop
customization queues representative preparation through the coordinator rather
than doing capture or palette extraction in a panel callback.

The playlist-occurrence editor is library-first too. Its still, video, and
Workshop source tabs each materialize one six-card page from the indexed
library, so changing an occurrence never requires an absolute media path or a
typed Workshop ID. Dynamic entries reuse the same representative-still picker
and collapsed manual representative-path escape hatch. Rebinding keeps the
occurrence ID, list position, and insertion timestamp. Representative-still and
palette changes are saved as the selected medium's shared item-profile defaults
and therefore refresh every occurrence linked to that medium; they are not a
private per-occurrence override.

Shop routes render fixed 12-card local pages even when a provider returns 36–48
items. Preview identity validation is memoized for the current result generation
and one bounded `preview.sync` request advances from the normal update path;
frame callbacks advance only bounded drag, still-choice, Workshop-index, and
palette-index reconciliation, and never construct a complete panel tree. Result
cards own their direct download/quality controls and expose installed, queued,
and active state; no duplicated selected-item hero is rendered above the grid.

## Coordinator and persisted state

The coordinator publishes a small protocol-4 lifecycle object on
`wall_in_one_status`. Larger documents are published only when dirty and are
referenced by revision:

| State key | Contents |
| --- | --- |
| `wall_in_one_config_state_v1` | schema-5 item-profile records, playlist snapshots, output assignments, per-display engines, schedules, and gestures |
| `wall_in_one_runtime_state_v1` | schema-6 pair provenance, playlist runs, output state, palette diagnostics, active Workshop IDs, and last capture |
| `wall_in_one_library_state_v1` | bounded image, video, and Workshop inventories plus incremental scan state |

The panel accepts a domain snapshot only when its service instance and revision
match the lifecycle object. Commands carry monotonically increasing nonces and
are never replayed automatically. The renderer, palette, Wallhaven, and
MotionBGS bridge use their own bounded versioned state keys. The generic
`backend` bridge publishes a separate status/result pair for asynchronous
library scans; the palette, preview, and Wallhaven consumers use the same exact
backend executable through their own bounded state/transport contracts.

The lifecycle snapshot's bounded `captures` map is also presentation state for
the item editor. The dedicated `pairing-preview` slot reports preparation in
progress. A successful editor-requested capture updates only the current
medium/source pair registry and library scan; it never writes the applied
per-output pair, changes Noctalia's wallpaper/palette, or starts a renderer.

Schema 5 retains the field name `pairings`, but this is item-profile and snapshot
plumbing rather than a catalog users must populate. Library items synthesize a
validated default bundle. Saving a customization creates or updates the stable
profile with `customized = true`; records predating explicit provenance are
normalized as customized to preserve their old behavior. Reset writes the same
profile ID with freshly derived defaults and `customized = false`, then
synchronizes every linked occurrence. All profiles are keyed by the static path
or dynamic medium/source identity, so customization and default changes update
one record instead of accumulating hidden duplicates. The source is display-only
in the item-profile customization editor: filesystem and Steam inventory own
library identity. The separate playlist-occurrence editor may rebind its one
occurrence through the graphical library picker described above.

A playlist occurrence has its own stable entry ID, a validated bundle snapshot,
and an optional `pairing_id` link. Linked edits and resets refresh those
snapshots. `playlist_replace_entry` rebinds one occurrence while preserving its
ID, position, and insertion timestamp, then resolves the selected medium's
shared profile instead of rewriting the old profile under a new identity. There
is no public pairing-delete command. If a source disappears from the
authoritative index, the panel stops presenting an orphan Library card while
existing playlist snapshots remain visible as missing until removed or
restored.

The shared-state watcher only projects `playlist_replace_entry` into a fixed
primitive-only queue. Full configuration normalization and persistence run one
request at a time from the ordinary coordinator update callback, so an editor
save cannot spend the state callback's tighter CPU budget walking the project.

Each display stores a pinned default playlist, ordered schedule rules, optional
playlist playback overrides, and its own engine configuration. Playlist cards
can be dragged onto the fixed first row or into the scheduled suffix; scheduled
rows are draggable, and when multiple enabled rules match, the lowest visible
row wins.
All of these controls share the display's combined page beneath **Home**.
Schema 1–4 outputs receive the documented schema-5 engine defaults during
migration; afterward the settings live only with that display. This avoids
reading retired global engine values. Four invisible manifest declarations
accept old host-owned overrides because API 17 has no configuration-deletion
binding; no runtime reads those inert compatibility fields.

## Per-display engine configuration

`outputs[output].engines` is validated as one object:

```text
layer
video.enabled
video.mute
video.hardware_decode
video.auto_pause
video.auto_pause_mode
video.options
workshop.enabled
workshop.fps
workshop.volume
workshop.silent
workshop.scaling
workshop.clamp
workshop.flags.*
```

The defaults are `bottom` layer; video enabled, muted, hardware decoding and
auto-pause enabled with mode `FULL`; and Workshop enabled at 30 FPS, volume 0,
silent, `fill` scaling, and `border` clamping. Video auto-pause mode is one of
`FULL`, `MAX`, or `ACTIVE`. Workshop FPS is 5–144, volume is 0–100, scaling is
`default`, `stretch`, `fit`, or `fill`, and clamp mode is `clamp`, `border`, or
`repeat`.

Workshop flags are `noautomute`, `no_audio_processing`, `disable_particles`,
`disable_mouse`, `disable_parallax`, `no_fullscreen_pause`, and
`fullscreen_pause_only_active`. The last two cannot both be enabled. Video
options are bounded text and are parsed by the owned renderer boundary; they
are not a shell command.

Changing one display's engines reconciles only the Wall-in-One child owned for
that display. It does not rewrite another display's settings or interrupt its
playlist run.

## Owned renderer and capture boundary

The renderer service starts `mpvpaper` for local video and
`linux-wallpaperengine` for installed Workshop projects. One cancellable Bash
supervisor is a foreground `runStream` child; both renderer commands remain
foreground descendants in that process group. The supervisor records exact
child PIDs and never uses `pgrep`, `pkill`, detached systemd scopes, or a PID
file owned elsewhere.

At most one dynamic child is owned per display. Replacing video with Wallpaper
Engine, or the reverse, is break-before-make: the exact old child exits before
the replacement is recorded. Distinct displays may run different engines at
the same time. A failed synchronous replacement does not resurrect the old
child. Output removal, stop, plugin reload, disable, and service exit drain only
the children in this supervisor's process group.

`bottom` is the portable layer default. `background` is available for
compositor-specific layouts such as a niri `place-within-backdrop` rule.
Wallpaper Engine accepts `background` only when the installed command advertises
`--layer`; otherwise that start fails closed.

mpvpaper always supports exact-child stop and signal fallback for pause,
resume, and toggle. Private socket controls add pause plus mute, unmute,
toggle-mute, and volume when `socat`, or a compatible Unix-socket `nc`, is
available. Wallpaper Engine supports stop and signal-based pause, resume, and
toggle; it does not advertise runtime audio controls that
`linux-wallpaperengine` does not provide.

An unexpected exit after startup advances an armed multi-entry playlist only
after a per-display 10, 20, 40, 80, 160, then 300-second delay. A replacement
that remains alive for 60 seconds resets the sequence. Explicit display or
playlist intent clears it.

Rendered Workshop capture uses the same exact owner. The coordinator allocates
a private `pluginDataDir()/staging/capture-*.png`, and the supervisor runs
`linux-wallpaperengine --screenshot` with the validated output, project path,
layer, and per-display Workshop settings. The configured delay is clamped to
the command's one-to-five-frame range. A result must be non-empty, stable, and
closed by the child before it is signature-validated, optionally decoded by
FFmpeg, and atomically installed. A still-current displaced Workshop child may
then be restored; stale, cancelled, or superseded callbacks cannot start it.

## Roots, libraries, and deletion authority

The image and video roots are independent settings. Each must be explicitly
selected and already exist. Wall-in-One does not fall back to Noctalia's
wallpaper directory, copy one root into the other, create a selected root, or do
work for a capability whose matching root is unavailable.

- The image library, Wallhaven downloads, manual exports, and automatic stills
  require the image root.
- The local-video library and MotionBGS metadata/download path require the video
  root.
- A Workshop project can be discovered from Steam, but applying or capturing it
  requires a valid representative in the image-root workflow.
- Direct Wallhaven, MotionBGS, Steam, and Workshop links remain available even
  when local storage is not ready.

Managed children are derived, not separately configurable:

| Location | Ownership |
| --- | --- |
| `<image root>/Wall-in-One/Wallhaven` | validated Wallhaven JPG/PNG plus `.wallhaven.json` sidecar |
| `<image root>/Wall-in-One/Automatic Stills` | generated video/Workshop still plus `.wall-in-one.json` sidecar |
| `<video root>/Wall-in-One/MotionBGS` | validated MP4 plus `.motionbgs.json` sidecar |

Each Library medium page reports its root, derived directories, relevant
defaults, and Wall-in-One's private bounded metadata/preview cache locations.
Private caches remain under `pluginDataDir()` and are not presented as library
media. The MotionBGS bridge uses
`pluginDataDir()/motionbgs-bridge-v1/cache`; its short-lived schema-1 transport
files use that root's `rpc` child. No provider metadata storage or network
command is initialized before its matching root is ready; the palette service
is likewise dormant until the explicit image root exists.

Root files are user-owned and never deletable from the panel. A managed file is
deletable only when it is a direct child of the expected marked directory and
its adjacent sidecar proves Wall-in-One ownership. Deleting a managed MotionBGS
video may also remove only its managed automatic still. Missing files, root
changes, and Workshop unsubscribe events are observations, not deletion
instructions.

## External computation backend

Noctalia applies a CPU budget to every Luau callback. Bulk filesystem walks,
metadata parsing, sorting, and inventory paging are therefore delegated to the
separately installed Python 3.11+ executable `wall-in-one-backend`. The
`backend` service contains only fixed-command discovery, bounded transport,
nonce/cancellation handling, incremental result validation, and state
publication.

The service resolves a user-selected absolute executable from
`backend_binary_path`, then the single-line `pluginDataDir()/backend-path`
pointer, then the exact executable name `wall-in-one-backend` from PATH. Both
absolute-path tiers require a non-empty regular executable and reject control
characters; no tier accepts a shell command. The retired
`motionbgs_binary_path` manifest key remains invisible, but the isolated
MotionBGS bridge still honors a valid legacy helper after the two shared
absolute-path tiers and before PATH. Other backend capabilities never execute
that compatibility-only program.

The bundled `scripts/backend-provider` launcher probes
`WIO-BACKEND-PROBE1` schema 1 for the exact capability set `library.scan`,
`palettes.inventory`, `preview.sync`, `wallhaven.search`,
`wallhaven.detail`, `wallhaven.download`, and `wallhaven.clear`. Requests are
at most 64 KiB; every action has an exact schema, a revocable guard, a bounded
deadline, and current-user-owned direct-child transport files. Responses and
inventory pages are at most 128 KiB. The Luau bridges validate bounded batches
and publish only complete nonce-matched results.

Generic interface 1 moves user/managed image and video inventory, sidecar
ownership, Workshop metadata, representative lookup, sorting/paging, external
custom/community palette inventory, provider-preview cache maintenance, and
Wallhaven network/result/download work. Stable storage remains
`pluginDataDir()/backend-bridge-v1/rpc` for library transport,
`pluginDataDir()/palettes-cache.json` plus `.bak` for the palette catalog,
`pluginDataDir()/provider-previews/v1` for preview files and its LRU manifest,
and `pluginDataDir()/wallhaven-bridge-v2/rpc` for Wallhaven transport.

Custom palette discovery has one narrow read-only exception to the normal
no-symlink boundary. The configured palette directory and individual JSON files
may resolve through NixOS/Home Manager symlinks, including root-owned Nix-store
targets. The backend holds a stable directory descriptor, opens each exact name
relative to it, validates regular-file identity and bounded size with `fstat`
before and after reading, and reads only from the opened descriptor. Transport,
cache, response, marker, download, and media write boundaries still reject
symlinks and foreign ownership.

Noctalia wallpaper/palette calls, adaptive `noctalia theme` palette preview and
source hashing, coordinator IPC, renderer child lifecycle, and exact-PID
ownership remain host-coupled. Schedule resolution stays local because it is a
small time-sensitive calculation; config normalization and managed deletion
remain coupled to coordinated persistence/commit checks. A one-shot process for
those paths would add serialization or race cost without removing a measured
callback hotspot.

If the backend is absent or incompatible, fresh library and external palette
inventory, provider preview refresh, and integrated Wallhaven/MotionBGS work
are unavailable; the last complete library and palette inventories remain
intact. Configured playlists, wallpaper/palette application, adaptive palette
preview, renderer controls, and direct provider links are not disabled.

## Wallhaven shop service

The `wallhaven` service is a thin host bridge over the backend's complete
Wallhaven integration. The Python action uses only documented
`https://wallhaven.cc/api/v1` routes and validated Wallhaven image/thumbnail
hosts. The Luau service retains the schema-1 command/status/result keys and
incrementally validates normalized `search`, `detail`, `download`, and `clear`
responses; it performs no provider network I/O or image parsing.

Search accepts Wallhaven query syntax, category and purity masks, sort/order,
top-list range, minimum or exact resolution, ratios, color, and page. Stable
random pagination retains the returned seed. Responses are limited to 128 KiB
and 24 normalized results; starts are serialized by at least two seconds.
Downloads are capped at 64 MiB, must match a current result and advertised
JPG/PNG type, and atomically install both image and provenance without
overwriting an existing pair. The optional API key crosses the process boundary
only through a private mode-0600 handoff file and is then sent as an HTTP
header. Public SFW browsing works without it.

Status includes the current download's `active_id`. The panel intersects that
identifier with managed-library `provider_id` records, so a card moves from
available to downloading to already-on-disk and cannot enqueue an installed
item again.

## MotionBGS process boundary

MotionBGS has no stable public API. Version 0.7 removed its network,
HTML parser, provider cache, and download implementation from Noctalia's Luau
runtime. The `motionbgs` service is now a thin bridge: it has no `update()`
callback, watches the existing schema-1 command key, validates settings and
normalized results, serializes a bounded queue, and publishes the existing
schema-1 acknowledgement/status/result state.

Version 0.8 folds that implementation into the separately installed one-shot
Python 3.11+ program `wall-in-one-backend`, staged in the repository's top-level
`wall-in-one-backend/` directory. The generic and provider bridges share the
explicit-setting/pointer/PATH resolution tiers. The provider bridge invokes
`motionbgs-*` compatibility subcommands for the unified backend, or the old
`probe`/`rpc` names only when its legacy setting selected the pre-0.8 helper,
so its existing state protocol does not change.

Bridge status publishes `active_slug`, `active_quality`, and a queue-bounded
`queued_downloads` list. Exact slug/quality duplicates are rejected while
active or pending; unrelated qualities and items retain normal queue behavior.
The UI combines these fields with managed-library sidecars. The RPC is
one-shot, not streaming, so byte-level progress is intentionally unavailable.

The bundled `scripts/motionbgs-provider` launcher is a protocol and resource
gate, not a second parser. It resolves and verifies the executable, removes
ambient Python path injection, creates private bounded stdout/stderr files, and
applies an OS file-size limit before execution. A compatibility check runs:

```text
wall-in-one-backend motionbgs-probe --protocol 1
```

The exact probe record is `WIO-MBGS-PROBE1`, schema 1, and must advertise
`search,details,download,clear`. Each accepted command then creates one JSON
request of at most 8 KiB and one no-replace JSON response of at most 128 KiB
under `pluginDataDir()/motionbgs-bridge-v1/cache/rpc`. The launcher invokes one
`WIO-MBGS-RPC1` schema-1 operation and exits. The external program owns HTTP,
HTML parsing, its `motionbgs-bridge-v1/cache` data, request-rate serialization,
and managed MP4 installation; the Luau bridge validates the normalized result
again before publishing it.

Every RPC is also bound to a unique one-line cancellation guard in that same
private directory. The guard path appears in both the request and launcher
arguments. Configuration changes, service exit, and operation invalidation
remove it first; the helper checks it before network hops, at bounded
search/detail checkpoints, and immediately before no-replace installation.
Non-download work has a 30-second helper deadline. A cold download has a
75-second helper deadline inside an 80-second Noctalia process timeout, covering
the possible 20-second detail fetch, request spacing, and 50-second media fetch.

A download response carries `cached`, `source_url`, `fetched_at`, the complete
normalized `selected` detail record, and the `download` receipt. The bridge
cross-validates that detail and receipt against the requested slug, quality,
managed path, and installed provenance before updating results or status.

The external program uses public unauthenticated pages only. Curl's ambient
configuration is disabled. Every request is restricted to the MotionBGS HTTPS
origin; redirects are followed explicitly with a three-hop ceiling, strict
same-origin validation, and effective-URL equality for each hop. HTML is capped
at one MiB and parser tag/attribute work is bounded. Text search is unpaged;
latest, genre/tag, and 4K use validated previous/next routes; HD remains
first-page-only. Exact `/search?q=X` to `/tag:<normalized-X>/`
canonicalization is accepted, while a different tag, catalog, malformed path,
or cross-origin destination fails closed.

Details accept only a validated slug and downloads only numeric
`/dl/hd|4k/<id>/` routes. File-size limits are backed by `ulimit -f`; HTML and
MP4 MIME types are cross-checked with content signatures; cache and transport
files are bounded regular files; and an MP4 plus its provenance sidecar are
installed atomically without replacing an existing destination. The program
does not log in, bypass a challenge, execute page scripts, or crawl multiple
pages to manufacture results.

A same-origin download redirect is accepted only when its final `/dl/...` or
`/media/<id>/*.mp4` route still names the ID selected from the detail page. A
different ID, unexpected query, or unrelated same-origin route fails before a
file can be installed.

Missing, unreadable, or protocol-incompatible programs set bounded degraded
states for MotionBGS, Wallhaven, provider previews, and fresh library/external
palette inventory. Host-coupled wallpaper, adaptive palette preview, playlist,
and renderer actions continue normally, and the panel retains independent
direct-site and backend-download links.

The selector profile was independently implemented from the public site, with
WaifuX revision `ff44ecba11227ff965074ad3320096fa5827781c` used only as a
factual compatibility reference. WaifuX is GPL-3.0; no implementation code is
copied into this MIT plugin. Provider sidecars record origin and local ownership,
not a license grant.

## Palette service

The `palettes` service keeps pinned built-in/wallpaper-generator choices and
delegates bounded community/custom inventory work to the backend's
`palettes.inventory` action. The backend scans custom JSON, fetches and shapes
the community catalog, maintains its six-hour last-known-good cache, and emits
bounded inventory pages. The Luau bridge incrementally validates those pages
and never applies the active shell theme. The coordinator remains the only
entry executor and applies a validated still, theme mode, palette selection,
then owned dynamic renderer in that order.

Adaptive preview uses
`noctalia theme <image> --scheme <scheme> --both -o <file>` against a private
bounded output path. A 16-entry memory cache includes path, size, mtime,
SHA-256, and scheme. This adaptive preview and source hashing deliberately stay
in Luau because they call Noctalia's host CLI; they are not part of
`palettes.inventory`. Opening a panel route does not create a network poller.
Noctalia has one
global palette, so the configured display leader is the sole writer; without
one, deterministic transition order decides the latest writer.
