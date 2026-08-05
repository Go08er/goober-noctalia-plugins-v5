# Wall-in-One

Wall-in-One `0.8.0` is a Noctalia v5 wallpaper library for still images, local
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

- **Home** shows setup and readiness, with each detected display nested beneath
  it. Selecting a display opens one combined page with a visual playlist
  library, one ordered default-plus-schedule priority list, playback policy,
  and engine settings.
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
   Workshop entries use a validated preview or automatic still. Every item is
   immediately usable with an implicit adaptive wallpaper palette; no separate
   pairing-creation step is required. Customize only the items that need a
   different still or palette.
2. When the separately installed backend is available, search Wallhaven's
   official API or MotionBGS's bounded public pages under **Shops**. Download and
   quality controls live on each result card. Cards distinguish available,
   queued, downloading, and already-installed media, while MotionBGS keeps a
   compact persistent queue summary. Steam links remain available for acquiring
   and managing Workshop content.
3. Select a display beneath **Home**. Its one page combines renderer controls,
   rotate/shuffle and interval policy, a pinned default playlist, ordered
   calendar overrides, and its owned mpvpaper and `linux-wallpaperengine`
   settings. Editing one display does not rewrite another.
4. Add or drag cards from the playlist's visual pairing library into its
   ordered list, then drag existing rows to reorder them. **Edit** on an
   occurrence opens a six-card, paged image/video/Workshop picker instead of a
   raw source-path form. Choosing a different indexed item rebinds only that
   playlist position and preserves its stable ID, position, and insertion time.
   Its representative still and palette remain the selected media item's shared
   defaults everywhere that item is used. Duplicate or remove the source itself
   to add or remove library identities.
5. On a display page, drag a playlist onto row 1 to make it the unscheduled
   default, or between later rows to configure a scheduled override. Month,
   weekday, and local-time rules are evaluated in visible order, with the
   lowest matching override taking priority.

Direct **Apply** creates or replaces that display's one-entry **Quick Choice**
playlist, so manual and scheduled changes share the same executor and safety
checks. Disable Noctalia's separate native slideshow on displays governed by a
Wall-in-One schedule; Noctalia v5 has no public command for coordinating those
two timers.

Provider previews are synchronized by the external backend through a strict
thumbnail launcher and shown to `ui.image` only as local files. The private
`pluginDataDir()/provider-previews/v1` cache is
capped at 64 entries, 64 MiB total, and 2 MiB per file. A failed preview leaves
metadata, the provider-site action, and download controls usable. Search
responses are locally paged in fixed 12-card views; preview validation is
memoized per result generation, and one bounded backend synchronization is
advanced from the normal update path. Complete panel trees are never rebuilt
from a frame callback. Large still, Workshop, palette, and shared-profile
indexes are reconciled in fixed batches and atomically swapped; editing one
playlist occurrence hides the unrelated add drawer and other playlist rows.

The panel requests a roomy 1160 × 780 floating surface. Fixed dimensions keep
the hub usable if an older saved Noctalia placement override survives an
upgrade, without triggering the panel manager's fill-sizing warning.

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

Opening a video or Workshop item's customization—either from its Library card
or a playlist occurrence—eagerly requests its automatic representative through
the coordinator's bounded capture queue. The editor shows pending, preparing,
and ready states, and the generated still is cached by the medium/source identity
before the wallpaper-derived palette preview runs. Choosing a specific
representative uses a paged picker over indexed user-owned and Wallhaven stills;
a collapsed manual absolute-path field remains an explicit escape hatch.
Preparing a still does not apply a wallpaper, palette, or renderer.

The representative remains Noctalia's real wallpaper for lock-screen fallback,
wallpaper hooks, overview/backdrop consumers, and wallpaper-derived colors while
the dynamic layer renders above it.

## Per-item Noctalia themes

Each item resolves dark/light/auto mode plus a built-in, wallpaper-generator,
community, custom, or explicit keep-current policy. The implicit default is
adaptive wallpaper colors. The installation-wide default toggle starts enabled
and may instead make new items keep the current theme; saving an optional
customization gives that item a durable override. Application order is still,
theme mode, palette, then owned renderer.

Adaptive previews use Noctalia's non-applying theme command against the selected
or generated still. The palette service keeps a bounded SHA-256-aware adaptive
preview cache; the backend maintains a six-hour last-known-good community
catalog. Declarative NixOS/Home Manager custom palettes may be read through
symlinks into the Nix store; this exception is read-only and does not apply to
plugin caches, transport files, downloads, or media-library paths. Noctalia has one shell palette,
so an optional leader display is the sole writer; otherwise deterministic
transition order makes the latest successful apply authoritative.

## External backend installation

Noctalia budgets every Luau callback and disables extensions that repeatedly
overrun it. Wall-in-One therefore keeps UI construction, Noctalia host calls,
IPC dispatch, and exact-PID renderer ownership in Luau, while bounded bulk work
crosses a process boundary. Release 0.8 moves filesystem library scanning,
external palette inventory, provider-preview cache maintenance, Wallhaven
transport/response shaping/downloads, and the already-extracted MotionBGS
provider work into one executable. Schedule resolution, configuration
normalization, managed-delete transactions, and host API calls stay in Luau.
The graphical entry editor's state callback performs only a fixed scalar
projection; full normalization and persistence are serialized on later service
updates through a bounded queue.

Install the one-shot Python 3.11+ executable from this repository's top-level
[`wall-in-one-backend/`](../wall-in-one-backend/) directory as
`wall-in-one-backend` on `PATH`, or select its absolute path with the advanced
**Wall-in-One backend program** setting. Wall-in-One never downloads, updates,
or executes newly downloaded code automatically.

For a checkout you already trust, verify the tracked digest before installing:

```bash
cd /path/to/goober-noctalia-plugins-v5
(cd wall-in-one-backend && sha256sum -c wall-in-one-backend.sha256)
install -Dm755 wall-in-one-backend/wall-in-one-backend \
  "$HOME/.local/bin/wall-in-one-backend"
wall-in-one-backend self-test
wall-in-one-backend probe --protocol 1
```

Once a 0.8 release publishes the executable and sibling checksum assets,
download them as data, verify them, and only then grant execute permission.
These commands are not a claim that those release assets already exist:

```bash
version='0.8.0'
base="https://github.com/Go08er/goober-noctalia-plugins-v5/releases/download/wall-in-one-v${version}"
tmp="$(mktemp -d)" || exit 1
curl --fail --location --max-redirs 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$tmp/wall-in-one-backend" "$base/wall-in-one-backend"
curl --fail --location --max-redirs 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$tmp/wall-in-one-backend.sha256" "$base/wall-in-one-backend.sha256"
(cd "$tmp" && sha256sum -c wall-in-one-backend.sha256) || exit 1
chmod 0755 "$tmp/wall-in-one-backend"
install -Dm0755 "$tmp/wall-in-one-backend" \
  "$HOME/.local/bin/wall-in-one-backend"
rm -rf -- "$tmp"
wall-in-one-backend self-test
```

The checksum detects corruption or replacement relative to the downloaded
checksum. Because both files come from the same release host, verify the release
tag/account through a separately trusted GitHub view when provenance matters.
Ensure `$HOME/.local/bin` is in the environment inherited by Noctalia, or use
the advanced absolute-path setting.

The schema-1 executable advertises `library.scan`, `palettes.inventory`,
`preview.sync`, and all four `wallhaven.*` actions; each thin bridge checks the
capabilities it consumes. MotionBGS uses compatibility
subcommands on the same executable and requires search/details/download/clear.
If the backend is absent, unreadable, or incompatible, local-library refresh,
external palette inventory, provider preview refresh, and both integrated
provider shops degrade. The last complete in-memory library and palette
inventories are not replaced by partial results. Host-coupled wallpaper and
palette application, adaptive palette previews, configured playlists, renderer
control, and provider-site links remain available. The relevant pages explain
the detected state and retain a **Get backend** or direct-site route.

## MotionBGS process boundary and fallback

MotionBGS has no versioned public API, so its integration remains optional and
process-isolated. Wall-in-One ships a thin `motionbgs` Luau bridge and a bounded
launcher, but not an in-process HTTP client or HTML parser. The bridge invokes
the same `wall-in-one-backend` executable through its `motionbgs-probe` and
`motionbgs-rpc` compatibility subcommands.

The bridge publishes the active download's slug and quality plus a bounded view
of queued downloads. The panel combines that state with the managed video
library, disables exact duplicates, and labels completed qualities as already
on disk. The helper protocol does not stream byte-level progress, so the UI
reports honest queued/active/completed phases rather than inventing a percent.

Each operation is a new backend process. The bridge writes one schema-1 JSON
request of at most 8 KiB and accepts one schema-1 JSON response of at most
128 KiB. Request/response transport lives under
`pluginDataDir()/motionbgs-bridge-v1/cache/rpc`; the external program owns its
bounded metadata cache in the parent
`pluginDataDir()/motionbgs-bridge-v1/cache`. The bridge has no `update()`
callback and performs no provider HTTP, HTML parsing, cache maintenance, or
media download work inside Noctalia's Luau runtime.

The backend uses only public unauthenticated pages, serializes network
starts at least one second apart, and accepts only the MotionBGS HTTPS origin.
Ambient curl configuration is disabled. Redirects are followed explicitly,
remain same-origin, and require each curl effective URL to equal the requested
URL. HTML and MP4 size limits have an OS file-size backstop; declared MIME is
cross-checked against content signatures; downloads use atomic no-replace
installation plus provenance sidecars. It does not log in, bypass challenges,
execute page scripts, or crawl in bulk.

Text search is unpaged. Latest, genre/tag, and 4K catalogs use validated
previous/next routes; HD is first-page-only while later HD pages redirect to an
unfiltered catalog. MotionBGS may canonicalize `/search?q=X` to
`/tag:<slug>/`; the helper accepts only a same-origin tag exactly equal to the
normalized query. Mismatched catalogs, unsafe paths, changed markup, and
cross-origin destinations fail closed. **Open MotionBGS** remains available if
the helper is missing or the site changes.

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
| Services | `coordinator`, `backend`, `renderer`, `motionbgs`, `palettes`, `wallhaven` |
| Widget | `wall-in-one` |
| Panel | `hub` |
| Control Center shortcut | `wall-in-one-shortcut` |

## Requirements

Manifest dependencies are `bash`, `curl`, and `sha256sum`; capabilities still
fail soft at runtime. Optional commands are:

- Python 3.11+ and the separately installed `wall-in-one-backend` program for
  local-library indexing, external palette inventory, provider preview cache,
  Wallhaven integration, and MotionBGS search/details/cache/download work;
- `ffmpeg` for still extraction and validation;
- `mpvpaper` for video playback;
- `linux-wallpaperengine` for Workshop playback and rendered capture;
- `socat`, or compatible Unix-socket `nc`, for mpvpaper audio IPC;
- `steam` or `xdg-open` for Steam/Workshop links; and
- `xdg-open` for direct provider-site fallbacks.

Network failures affect only their backend-backed capability. A missing backend
also prevents a fresh local-library index, external palette inventory, and
provider preview refresh, but does not erase the last complete inventories or
disable configured playlists, direct links, Noctalia wallpaper/palette calls,
adaptive palette previews, or renderer controls. Python 3.11+ is not an
enable-time manifest dependency; it is required for those external capabilities
and the two integrated provider shops.

## Settings

Installation-wide settings are intentionally limited to provider policy,
explicit image/video roots, capture/item defaults, palette authority, and
new-playlist defaults. Each Library page groups its medium's root,
derived/private locations, and defaults. Engine playback settings live on the
combined page for each display nested beneath **Home**, not on one global
settings wall.

Leave **Wall-in-One backend program** empty to detect the fixed
`wall-in-one-backend` name on `PATH`, or select an absolute executable path.
Wall-in-One does not accept an arbitrary shell command in this setting. The
retired `motionbgs_binary_path` key remains invisible so old Noctalia
configuration does not produce an unknown-setting warning. Runtime code never
reads it; `backend_binary_path` and the fixed PATH command are authoritative.

MotionBGS defaults are HD, 48 results, 30-minute metadata TTL, and 256 MiB
maximum download; bounds are 1–48 results, 5–1,440 minutes, and 16–512 MiB.
The MIT license covers plugin code, not downloaded artwork. Provider sidecars
record provenance and deletion authority, not redistribution permission.

## Architecture

Noctalia loads each manifest entry into an isolated `ScriptRuntime`; the pinned
Luau surface has no supported shared-module loader. The coordinator and panel
therefore remain self-contained, while services communicate through bounded,
versioned state. Thin process/file clients in `backend.luau`, `palettes.luau`,
`wallhaven.luau`, and the panel invoke `library.scan`, `palettes.inventory`,
`wallhaven.*`, and `preview.sync` through exact bounded RPC. Library and palette
results use fixed-size pages that their Luau bridges validate incrementally
before publishing one complete inventory. The separate `motionbgs.luau` bridge
uses compatibility subcommands on that same program and contains no HTTP or
HTML parser.

Host calls and process state stay where they are reliable: wallpaper/palette
application, adaptive `noctalia theme` preview generation and source hashing,
notifications, IPC routing, renderer-child lifecycle, and exact PID ownership
remain in Luau or the existing renderer supervisor. Schedule resolution is a
small time-sensitive computation, while configuration normalization and managed
deletion are coupled to coordinated persistence/commit checks; spawning a
one-shot process there would add serialization or race cost without removing a
measured callback hotspot. Those boundaries therefore stay in Luau in 0.8.
A later reduction would have to move the complete configuration mutation
transaction—revision check, normalization, persistence plan, and commit result—
as one asynchronous protocol. Extracting individual validators while retaining
their synchronous callers would only duplicate logic or reorder failures.

## Stored state and upgrades

`config.json` schema 5 stores item profiles, playlist snapshots, per-display
engine settings, fallback assignments, and ordered schedules. Its internal
`pairings` map is plumbing rather than a required user-created catalog: the
authoritative library index supplies one implicit identity for each media file
or Workshop scene, while a saved override records `customized = true`.
Reset rewrites that stable profile with the item's derived defaults,
`customized = false`, and synchronizes linked playlist snapshots. A playlist
add after defaults change reuses the same medium/source profile, refreshes all
linked snapshots, and does not allocate a second same-source profile. An
unindexed source no longer appears as a fake Library card; an existing playlist
occurrence retains its stable ID and last validated snapshot so it can be
removed deliberately or become usable again if the source returns.

`runtime.json` schema 6 stores capture provenance, independent run state,
palette diagnostics, and exact owned Workshop state. Older action values are
normalized to owned equivalents. Schema 1–4 outputs receive the documented
schema-5 engine defaults and can then be tailored per display. Noctalia has no
plugin-side API for deleting old plugin-setting overrides, so the manifest
retains four invisible, inert compatibility declarations for the retired
pre-0.7 global engine keys. Runtime code never reads them; their sole purpose is
to keep existing user configurations valid while per-display controls remain
authoritative.

Documents are bounded to 8 MiB, fully validated, journaled, and backed up before
a coordinated migration. Unknown/corrupt schemas fail closed and remain visible
in Diagnostics.

## Current testing boundary

Offline and VM gates cover schema migration, root gating, provider bounds,
generic backend probe/RPC isolation, paged library and palette inventory,
provider-preview synchronization, Wallhaven and MotionBGS RPC, external parser
and route validation, exact renderer ownership, capture, item profiles,
playlist snapshots, and schedules.
A real disposable Wayland session is still required to judge compositor layer
ordering, GPU rendering, audio, and visual theme propagation; mpvpaper is not
installed on the current host, so live internal video playback is not claimed.

```bash
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
nix build -L path:.#vm-test-wall-in-one
```

See [ADAPTERS.md](ADAPTERS.md), [TESTING.md](TESTING.md), and
[`tests/manual/wall-in-one.md`](../tests/manual/wall-in-one.md).
