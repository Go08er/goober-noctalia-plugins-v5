# Wall-in-One provider and renderer architecture

Wall-in-One `0.6.0` has three integration boundaries: Noctalia's public
wallpaper and theme APIs, provider services shipped by Wall-in-One, and dynamic
wallpaper processes started and supervised by Wall-in-One. It does not discover,
open, signal, or exchange state with separate wallpaper extensions; all shop
and renderer behavior belongs to Wall-in-One.

## Routed panel

Noctalia plugins cannot create independent application windows. Wall-in-One
therefore uses one normal panel configured as a full-size floating view
(`width = "fill"`, `height = "fill"`). Its hierarchy is local Luau route state,
not a collection of simultaneously rendered sections:

- **Home** — readiness, setup, and concise status, followed by one inset route
  per detected display;
- each display route — one combined page containing renderer controls,
  rotate/shuffle and interval policy, a pinned default playlist, draggable
  scheduled overrides, and per-display video/Workshop engine settings;
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
MotionBGS services use their own bounded versioned state keys.

Schema 5 retains the field name `pairings`, but this is item-profile and snapshot
plumbing rather than a catalog users must populate. Library items synthesize a
validated default bundle. Saving a customization creates or updates the stable
profile with `customized = true`; records predating explicit provenance are
normalized as customized to preserve their old behavior. Reset writes the same
profile ID with freshly derived defaults and `customized = false`, then
synchronizes every linked occurrence. Non-custom profiles are keyed by the
static path or dynamic medium/source identity, so changing defaults updates one
record instead of accumulating hidden duplicates.

A playlist occurrence has its own stable entry ID, a validated bundle snapshot,
and an optional `pairing_id` link. Linked edits and resets refresh those
snapshots. Actual record deletion is a separate internal operation: it clears
the links but deliberately leaves each last valid snapshot and media intact.

Each display stores a pinned default playlist, ordered schedule rules, optional
playlist playback overrides, and its own engine configuration. Scheduled rows
are draggable; when multiple enabled rules match, the lowest visible row wins.
All of these controls share the display's combined page beneath **Home**.
Schema 1–4 outputs receive the documented schema-5 engine defaults during
migration; afterward the settings live only with that display. This avoids
reading removed, undeclared manifest keys, which current Noctalia intentionally
rejects.

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
media. No provider metadata storage or network command is initialized before
its matching root is ready; the palette service is likewise dormant until the
explicit image root exists.

Root files are user-owned and never deletable from the panel. A managed file is
deletable only when it is a direct child of the expected marked directory and
its adjacent sidecar proves Wall-in-One ownership. Deleting a managed MotionBGS
video may also remove only its managed automatic still. Missing files, root
changes, and Workshop unsubscribe events are observations, not deletion
instructions.

## Wallhaven shop service

The `wallhaven` service owns the complete Wallhaven integration. It uses only
documented `https://wallhaven.cc/api/v1` routes and validated Wallhaven
image/thumbnail hosts. Supported commands are `search`, `detail`, `download`,
and `clear` on the schema-1 command/status/result keys.

Search accepts Wallhaven query syntax, category and purity masks, sort/order,
top-list range, minimum or exact resolution, ratios, color, and page. Stable
random pagination retains the returned seed. Responses are limited to 512 KiB
and 24 normalized results; starts are serialized by at least two seconds.
Downloads are capped at 64 MiB, must match a current result and advertised
JPG/PNG type, and atomically install both image and provenance without
overwriting an existing pair. The optional API key is supplied only through a
private header file. Public SFW browsing works without it.

## MotionBGS shop service

MotionBGS has no stable public API. The `motionbgs` service therefore uses only
public unauthenticated pages through a same-origin helper with curl configuration
disabled, a three-redirect cap, one-MiB HTML limit, and serialized one-second
request spacing. It does not log in, bypass a challenge, execute page scripts,
or crawl multiple pages to manufacture search results.

Text search is one unpaged result set. Latest, genre/tag, and 4K catalogs use
validated previous/next routes; HD remains first-page-only while MotionBGS
redirects later HD pages into the unfiltered catalog. Details accept only a
validated slug and downloads only numeric `/dl/hd|4k/<id>/` routes. MP4 files
are size/type/signature checked and atomically installed with provenance.

Listing parsing preserves one anchor per update callback so one complex card
cannot consume the host's callback CPU budget. The service switches from its
250ms idle cadence to 16ms only while parser state is active, then restores the
idle cadence on success, error, cancellation, configuration disable, launch
refusal, or exit. The live-like fixture contains 355 unrelated anchors and 36
cards: 391 anchors plus EOF and publication schedule 393 small callbacks, or
roughly 6.3 seconds instead of roughly 98 seconds at the idle cadence.

Pagination metadata is extracted in one pass over at most 32 `<link>` elements
within the first 16 KiB of the document head; the title-derived total hint uses
that same prefix. The bound removes the former full-document pagination scans
that could breach Noctalia's 25 ms update-callback deadline after card parsing.

MotionBGS may canonicalize an exact text tag search from `/search?q=X` to
`/tag:<slug>/`. Wall-in-One accepts that redirect only on the same origin and
only when the tag equals the normalized query (lowercase with normalized spaces
replaced by hyphens and still passing the strict slug validator). A different
tag, catalog route, malformed path, or cross-origin destination fails closed.
The same rule validates restored search-cache records.

The selector profile was independently implemented from the public site, with
WaifuX revision `ff44ecba11227ff965074ad3320096fa5827781c` used only as a
factual compatibility reference. WaifuX is GPL-3.0; no implementation code is
copied into this MIT plugin. Provider sidecars record origin and local ownership,
not a license grant.

## Palette service

The `palettes` service discovers bounded built-in, wallpaper-generator,
community, and custom choices but never applies the active shell theme. The
coordinator remains the only entry executor and applies a validated still,
theme mode, palette selection, then owned dynamic renderer in that order.

Adaptive preview uses
`noctalia theme <image> --scheme <scheme> --both -o <file>` against a private
bounded output path. A 16-entry memory cache includes path, size, mtime,
SHA-256, and scheme. Community metadata uses a six-hour TTL and last-known-good
cache; opening a panel route does not create a network poller. Noctalia has one
global palette, so the configured display leader is the sole writer; without
one, deterministic transition order decides the latest writer.
