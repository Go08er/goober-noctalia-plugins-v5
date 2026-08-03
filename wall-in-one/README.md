# Wall-in-One

Wall-in-One `0.6.0` is a Noctalia v5 wallpaper library for still images, local
videos, and installed Wallpaper Engine Workshop projects. Every dynamic source
is paired with a real still and a Noctalia theme policy. Named playlists can be
shared across displays while retaining independent playback, engine settings,
and schedules.

The pinned test source is Noctalia tag `v5.0.0-beta.7` (project/runtime version
`5.0.0`), using plugin API `17`.

## Usage

Open Wall-in-One from its bar widget, Control Center shortcut, or routed panel:

```bash
noctalia msg panel-toggle goober/wall-in-one:hub
```

Noctalia plugins cannot create standalone application windows. Wall-in-One
uses one normal full-size floating panel and local route state instead. Only the
selected route is rendered:

- **Home** shows setup and readiness.
- **Displays** → each output → **Overview**, **Engines**, **Schedule**.
- **Library** → **Images**, **Videos**, **Wallpaper Engine**.
- **Shops** → **Wallhaven**, **MotionBGS**, **Steam Workshop**.
- **Playlists** → each named playlist.
- **Diagnostics** contains detailed service and error state.

This hierarchy keeps shops, libraries, display controls, and playlist editors
out of one dense scrolling page. Inset routes are ordinary in-panel navigation,
not extra processes or panels.

Start on the matching **Library** page. Images, Videos, and Wallpaper Engine
each show their own selected root, derived managed locations, private caches,
and relevant defaults. The image and video roots are independent; each must be
explicitly selected in Noctalia's generated plugin settings and already exist.
Wall-in-One does not fall back to Noctalia's wallpaper directory, create either
selected root, or borrow one root for the other. Home remains setup-first while
either root is missing, and a capability performs no scan, directory creation,
download, export, network refresh, or cache initialization before its matching
root is ready.

The main workflows are:

1. Browse image, video, and installed Workshop libraries. Cards use stills like
   Noctalia's wallpaper browser: a static selects itself, while video and
   Workshop entries use a validated preview or automatic still. Each card is a
   pairing with a default adaptive wallpaper palette, not an untracked media
   row.
2. Search Wallhaven's official API or MotionBGS's bounded public-page service
   under **Shops**. Steam links remain available for acquiring and managing
   Workshop content.
3. Open one display's **Engines** route to configure its owned mpvpaper and
   `linux-wallpaperengine` behavior. Settings on one display do not rewrite
   another display.
4. Create reusable pairings and insert them into named playlists. Each playlist
   occurrence keeps a stable ID and validated snapshot.
5. Assign a fallback playlist and ordered schedule rules per display. Rotate or
   shuffle order, interval overrides, manual pinning, and month/weekday/time
   schedules are persisted independently.

Direct **Apply** creates or replaces that display's one-entry **Quick Choice**
playlist, so manual and scheduled changes share the same executor and safety
checks. Disable Noctalia's separate native slideshow on displays governed by a
Wall-in-One schedule; Noctalia v5 has no public command for coordinating those
two timers.

Provider previews are downloaded through a strict helper and shown to `ui.image`
only as local files. The private `pluginDataDir()/provider-previews/v1` cache is
capped at 64 entries, 64 MiB total, and 2 MiB per file. A failed preview leaves
metadata, source links, and download controls usable.

## Renderer ownership and per-display engines

Wall-in-One directly starts `mpvpaper` for video and
`linux-wallpaperengine` for Workshop projects. It does not hand playback to a
separate wallpaper extension. One API-17 renderer service owns a cancellable
Bash supervisor and exact foreground child PIDs. Reload, disable, output
removal, and exit drain that process group without `pgrep`, `pkill`, detached
systemd scopes, or unrelated PID files.

Exactly one dynamic child is owned per display. Switching engines is
break-before-make; distinct displays may run different engines concurrently.
A failed replacement does not silently restart the old source. Unexpected
post-startup exits use a per-display 10, 20, 40, 80, 160, then 300-second
playlist recovery delay, reset after 60 seconds of stable playback.

Each display stores:

- shared `bottom` or `background` layer;
- video enable, initial mute, hardware decode, auto-pause, `FULL`/`MAX`/`ACTIVE`
  auto-pause mode, and bounded mpv options; and
- Workshop enable, FPS, volume, silent mode, scaling, clamp mode, and validated
  render flags.

The defaults are `bottom`; video enabled, muted, hardware decode and auto-pause
enabled with `FULL`; and Workshop enabled at 30 FPS, volume 0, silent, `fill`,
and `border`. See [ADAPTERS.md](ADAPTERS.md) for exact ranges and flags.

mpvpaper supports stop and signal fallback for pause/resume/toggle. A compatible
private socket client also enables mute and volume controls. Wallpaper Engine
supports stop and signal-based pause/resume/toggle; unsupported runtime audio
controls remain disabled.

## Static pairs and generated stills

Every live apply resolves a real still before starting its renderer:

- video uses FFmpeg at the configured timestamp;
- Wallpaper Engine first attempts an owned
  `linux-wallpaperengine --screenshot` capture, then a validated source-video or
  Workshop-preview fallback; and
- an explicitly selected durable still always overrides automatic generation.

Automatic stills live in `<image root>/Wall-in-One/Automatic Stills` with
adjacent ownership sidecars. Manual exports go directly into the image root and
remain user-owned. Capture stages a unique private PNG, verifies stable output
and its image signature, optionally decodes it with FFmpeg, then installs it
atomically. Cancelled or superseded work cannot promote a still or start delayed
playback.

The representative remains Noctalia's real wallpaper for lock-screen fallback,
wallpaper hooks, overview/backdrop consumers, and wallpaper-derived colors while
the dynamic layer renders above it.

## Per-entry Noctalia themes

A pairing stores dark/light/auto mode plus a built-in, wallpaper-generator,
community, custom, or explicit keep-current policy. New library pairings default
to adaptive wallpaper colors. Application order is still, theme mode, palette,
then owned renderer.

Adaptive previews use Noctalia's non-applying theme command against the selected
or generated still. The palette service keeps a bounded SHA-256-aware cache and
a six-hour last-known-good community catalog. Noctalia has one shell palette,
so an optional leader display is the sole writer; otherwise deterministic
transition order makes the latest successful apply authoritative.

## MotionBGS provider and fallback

MotionBGS has no versioned public API. Wall-in-One uses public unauthenticated
pages only, serialized one second apart, with same-origin redirects, bounded
HTML/results/downloads, atomic MP4 installation, and provenance sidecars. It
does not log in, bypass challenges, execute page scripts, or crawl in bulk.
**Open MotionBGS** remains available if markup changes.

Text search is unpaged. Latest, genre/tag, and 4K catalogs use validated
previous/next routes; HD is first-page-only while later HD pages redirect to an
unfiltered catalog.

Listing parsing remains one anchor per callback for Noctalia's CPU budget. The
service temporarily uses a 16ms update cadence only while parsing, then restores
its 250ms idle cadence on every terminal path. A live-like 206-anchor page is
therefore scheduled in roughly 3.3 seconds instead of roughly 52 seconds.

MotionBGS may canonicalize `/search?q=X` to `/tag:<slug>/`. Wall-in-One accepts
only a same-origin tag exactly equal to the normalized query (lowercase, spaces
to hyphens, strict slug); mismatched catalogs and cross-origin redirects fail
closed. Cached search records use the same validation.

## Local libraries

The roots are scanned non-recursively. PNG, JPEG, WebP, and AVIF are images;
MP4, MKV, WebM, MOV, AVI, M4V, and GIF are video. If both settings point to the
same directory, GIF appears only in video. Direct-root files remain user-owned
and cannot be deleted from Wall-in-One.

Managed locations are derived and shown with their private cache locations on
the corresponding **Library** medium page:

| Location | Contents |
| --- | --- |
| `<image root>/Wall-in-One/Wallhaven` | validated Wallhaven image plus `.wallhaven.json` |
| `<image root>/Wall-in-One/Automatic Stills` | generated representative plus `.wall-in-one.json` |
| `<video root>/Wall-in-One/MotionBGS` | validated MP4 plus `.motionbgs.json` |

A file is deletable only as a direct child of its marked managed directory with
a matching sidecar. Explicitly deleting a managed MotionBGS video may also
remove only its managed automatic still. Missing files, root changes, and Steam
unsubscribe events never authorize deletion.

Wallhaven requests use its documented API and image hosts. Searches support its
query, category/purity, sort/order, top-list, resolution, ratio, color, and page
filters. Responses accept at most 24 items/512 KiB, starts are at least two
seconds apart, and downloads are capped at 64 MiB. An optional API key is sent
only as an `X-API-Key` header.

Workshop projects are discovered from standard Steam, Flatpak Steam, and Snap
Steam `content/431960` locations plus an optional explicit cache path. Bounded
`project.json` paths remain contained inside the numeric Workshop directory.

## Plugin

Manifest ID: `goober/wall-in-one`.

| Entry | ID |
| --- | --- |
| Services | `coordinator`, `renderer`, `motionbgs`, `palettes`, `wallhaven` |
| Widget | `wall-in-one` |
| Panel | `hub` |
| Control Center shortcut | `wall-in-one-shortcut` |

## Requirements

Manifest dependencies are `bash`, `curl`, and `sha256sum`; capabilities still
fail soft at runtime. Optional commands are:

- `ffmpeg` for still extraction and validation;
- `mpvpaper` for video playback;
- `linux-wallpaperengine` for Workshop playback and rendered capture;
- `socat`, or compatible Unix-socket `nc`, for mpvpaper audio IPC;
- `steam` or `xdg-open` for Steam/Workshop links; and
- `xdg-open` for direct provider-site fallbacks.

Network failures affect only the relevant shop. Downloaded media, local
libraries, pairings, playlists, and direct links remain available.

## Settings

Installation-wide settings are intentionally limited to provider policy,
explicit image/video roots, capture/pairing defaults, palette authority, and
new-playlist defaults. Each Library page groups its medium's root,
derived/private locations, and defaults. Engine playback settings belong to
**Displays → _output_ → Engines**, not one global settings wall.

MotionBGS defaults are HD, 48 results, 30-minute metadata TTL, and 256 MiB
maximum download; bounds are 1–48 results, 5–1,440 minutes, and 16–512 MiB.
The MIT license covers plugin code, not downloaded artwork. Provider sidecars
record provenance and deletion authority, not redistribution permission.

## Architecture

Noctalia loads each manifest entry into an isolated `ScriptRuntime`; the pinned
Luau surface has no supported shared-module loader. The coordinator and panel
therefore remain self-contained, while renderer and provider domains are
separate scheduled services communicating through bounded versioned state.

## Stored state and upgrades

`config.json` schema 5 stores pairings, playlists, per-display engine settings,
fallback assignments, and ordered schedules. `runtime.json` schema 6 stores
capture provenance, independent run state, palette diagnostics, and exact owned
Workshop state. Older action values are normalized to owned equivalents. Since
Noctalia rejects reads of settings removed from a manifest, schema 1–4 outputs
receive the documented schema-5 engine defaults and can then be tailored per
display without undeclared-setting warnings.

Documents are bounded to 8 MiB, fully validated, journaled, and backed up before
a coordinated migration. Unknown/corrupt schemas fail closed and remain visible
in Diagnostics.

## Current testing boundary

Offline and VM gates cover schema migration, root gating, provider bounds,
incremental parsing, route validation, exact renderer ownership, capture,
pairings, playlists, and schedules. A real disposable Wayland session is still
required to judge compositor layer ordering, GPU rendering, audio, and visual
theme propagation.

```bash
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
nix build -L path:.#vm-test-wall-in-one
```

See [ADAPTERS.md](ADAPTERS.md), [TESTING.md](TESTING.md), and
[`tests/manual/wall-in-one.md`](../tests/manual/wall-in-one.md).
