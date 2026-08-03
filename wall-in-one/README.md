# Wall-in-One

Wall-in-One `0.5.0` is a Noctalia v5 wallpaper hub for still images, local
videos, and Wallpaper Engine Workshop projects. Named playlists combine each
source with a real static representative and a complete Noctalia theme policy.
Outputs can share playlists while retaining independent run state and optional
month/weekday/time schedules.

The pinned test source is Noctalia tag `v5.0.0-beta.7` (project/runtime
version `5.0.0`), using plugin API `17`.

## Usage

Wall-in-One has five coordinated layers:

1. **Noctalia static wallpapers and colors.** Open the built-in wallpaper
   selector, use next/previous/random, persist a real still, then apply the
   entry's theme mode and `wallpaper`, `builtin`, `community`, or `custom`
   palette selection before live playback starts.
2. **Wallhaven.** Search Wallhaven's official API with its tag query, complete
   category/purity masks, sort/order/top-list range, minimum or exact
   resolution, ratio, color, and real previous/next page controls; inspect
   local cached still previews and details, and save a validated JPG or PNG into
   Wall-in-One's marked managed image directory. Public SFW search needs no key;
   an optional API key enables content for which Wallhaven requires
   authentication. The separate official `noctalia/wallhaven:browser` remains
   an optional panel fallback.
3. **MotionBGS and local video.** Search the public MotionBGS site or page
   through its latest, genre/tag, and 4K catalogs with a bounded best-effort HTML
   provider, inspect a cached thumbnail or poster still,
   download an item into a marked managed cache beneath the video root, generate
   a still with FFmpeg, and play it through an internally owned mpvpaper process.
   A direct **Open MotionBGS** link is always retained if the site's markup
   changes or the scraper is unavailable.
4. **Wallpaper Engine.** Scan Steam's ordinary Workshop `content/431960`
   cache, show installed projects, capture a rendered PNG through an internally
   owned `linux-wallpaperengine --screenshot` process, retain source-video and
   preview fallbacks, and apply the discovered local project through the same
   exact-PID owner. The hub also opens Wallpaper Engine through Steam and links
   directly to its Workshop for library management.
5. **Named playlists and schedules.** A playlist can mix stills, local videos,
   and Workshop IDs; each entry also stores its selected/automatic still and
   theme. Reusable pairing records can be placed into any playlist. Rotate and
   shuffle-bag order, a bounded per-playlist interval, independent per-output
   state, manual pinning, and month/weekday/time schedules are persisted. Rules
   are evaluated in displayed list order, with the lower matching rule winning.
   A one-entry playlist applies once and parks.

Wallhaven and MotionBGS results include still previews without handing remote
URLs to Noctalia's image renderer. The attached hub uses its bounded helper to
fetch the provider-validated Wallhaven `thumbs.large` image or MotionBGS
thumbnail/poster, then exposes only a local file through `ui.image`. The
panel-owned cache lives at
`pluginDataDir()/provider-previews/v1`, is capped at 64 entries and 64 MiB in
aggregate, and rejects any individual preview over 2 MiB. Fetches accept only
the providers' strict image origins and never follow redirects. A missing,
rejected, or failed preview leaves the normal image placeholder and all result,
source-link, and download controls usable. MotionBGS previews are still images,
not streamed or downloaded preview video; **Open MotionBGS** remains the backup
path if its scraper or preview source changes.

Direct **Apply** commands replace the selected output's one-entry **Quick Choice**
playlist, so manual and scheduled application share the same executor and
safety checks.

The bar widget retains Noctalia's searchable glyph selector, label toggle,
theme-token color, and independent left/middle/right action mappings. The
Control Center shortcut uses the same singleton coordinator.

> **Turn off Noctalia's native wallpaper slideshow/automation on any output
> controlled by Wall-in-One playlists.** Noctalia v5 exposes wallpaper switch
> commands but no public plugin API to pause or coordinate its own slideshow.
> Leaving both timers enabled creates two independent writers and can change the
> backing still between Wall-in-One transitions.

## Renderer ownership and backend modes

Wallpaper Engine and mpvpaper each have `auto`, `external`, and `internal`
backend modes:

- `auto` prefers an enabled external plugin. Its documented public panel and
  pause/stop/next controls remain available, but those plugins do not expose
  public apply-by-file or apply-by-Workshop-ID IPC.
- `external` never starts a Wall-in-One renderer.
- `internal` enables apply-by-source and mixed live cycling when the matching
  renderer command is installed.

Wall-in-One refuses internal startup while the corresponding external plugin
is still enabled. This is an ownership conflict, not an automatic takeover;
disable the external plugin first. Independent integration toggles default on
for native Wallhaven, MotionBGS, W Engine, mpvpaper, and a configured custom
panel. Each can force off only Wall-in-One's corresponding integration without
disabling or killing another plugin.
Enabled-plugin discovery also runs periodically and on explicit refresh. If a
refresh arrives while one is already active, Wall-in-One retains exactly one
follow-up request; a hot-swap therefore converges without growing an IPC or
subprocess queue.

`mpvpaper` and `linux-wallpaperengine` can coexist as installed commands. For
Wall-in-One-owned playback, the coordinator enforces exactly one dynamic child
per output: changing source or backend stops that exact child and starts the
replacement, while distinct outputs may use different backends concurrently.
This is a break-before-make switch, not a gapless transition: if the replacement
fails to launch, the old child is not automatically resurrected. Wall-in-One
does not attempt same-output layer-surface overlap and never kills a renderer it
did not start. Consequently, guaranteed ownership-safe switching applies to the
internal owner. External-plugin handoff remains limited to those plugins'
documented public controls, and an external provider of one type can still
overlap an internal or external provider of the other type if the user starts
both independently.

One API-17 renderer service owns one cancellable Bash supervisor with
`runStream`. Every `mpvpaper` or `linux-wallpaperengine` process remains a
foreground child in that process group. The supervisor tracks exact child
PIDs, and Noctalia terminates the entire group on plugin reload, disable, or
shutdown. It does not use `pgrep`, `pkill`, detached systemd scopes, or a
foreign PID file.

One shared **Internal renderer layer** setting controls both owned mpvpaper and
Wallpaper Engine children. `bottom` is the portable default; `background` is
available for compositors such as niri, where it can be paired with a
`place-within-backdrop` layer rule. Layer ordering and overview behavior remain
compositor-dependent, so both modes still require a real desktop check. The
selection applies to subsequent internal starts and captures. An installed
renderer that does not advertise `--layer` is limited to `bottom` and rejects a
requested `background` start instead of silently ignoring it.

Noctalia's ordinary static wallpaper surface remains enabled in either mode.
Wall-in-One never needs to queue a restoration side effect during API-17
teardown: the exact owned child disappears with its `runStream` process group,
while the persisted Noctalia still remains available underneath. Wall-in-One
also leaves that pairing's theme mode and palette selection configured rather
than restoring an older theme. On the next desktop start, Noctalia can therefore
load the last static backing and colors before Wall-in-One resumes any dynamic
layer.

The internal control surface is capability-driven. mpvpaper exposes stop and
pause/resume/toggle; with a compatible private-IPC client it also exposes
mute/unmute/toggle-mute and volume. Wallpaper Engine exposes stop and
signal-based pause/resume/toggle; upstream does not provide a comparable
runtime audio IPC, so its mute and volume controls remain unavailable instead
of pretending a setting changed.
`stop` ends and forgets the owned child; `resume` applies only to a child that
is still owned and paused, while applying the source again performs a restart.
Each user action sends one command with one monotonic nonce and is never
automatically replayed. A bounded handful of status writes may describe queue,
delivery, outcome, or recovery for that action. Idle supervisor heartbeats do
not publish unchanged state; a heartbeat may publish only when it proves a
pending FIFO write was consumed.

If an owned renderer survives startup but later exits unexpectedly, an armed
multi-entry playlist does not immediately churn through replacements. Recovery
advances after a transient per-output 10, 20, 40, 80, 160, then 300-second
backoff, capped at five minutes. A replacement must actually run for at least
one minute before a later exit resets that sequence; an explicit
playlist/output transition clears it.

## Static pairs and generated stills

Every live apply first resolves a static pair:

- Local videos use FFmpeg at the configured timestamp.
- When an internally owned Wallpaper Engine project needs a generated still,
  Wall-in-One first requests a native rendered PNG from
  `linux-wallpaperengine --screenshot`. The existing default of 15 and
  1–120-frame setting range remain compatible with cooperative adapters;
  internal capture clamps its value to linux-wallpaperengine's upstream
  five-frame maximum.
- If native or cooperative rendered capture is unavailable or fails, Wallpaper
  Engine video projects use their source video and scene/web projects use the
  Workshop preview.
- A manually selected durable image can be validated and applied directly as a
  standalone Noctalia backing.

**Pair configured still** validates the configured image, converts an animated
GIF to a durable PNG when needed, and immediately makes that image the selected
output's standalone Noctalia backing. It does not implicitly attach the image
to the next video or Workshop action. To keep a particular static image bound
to dynamic media across reloads, choose **Selected still** and its path in that
playlist entry. **Automatic still** instead reuses a valid source-to-still cache
entry or generates one and records its size/modification-time fingerprint.

**Image wallpaper directory** is the user-owned still root. Leave it empty to
use Noctalia's configured wallpaper directory; an explicit directory must be
absolute. Manual exports are saved directly in that root. Default-on automatic
video and Workshop pairs are saved under
`Wall-in-One/Automatic Stills`, beside a marker and per-file ownership
sidecar. Turning automatic capture off leaves Noctalia's current still
untouched and does not delete a valid cached automatic pair. With automatic
capture off, an uncached dynamic entry must have an explicitly selected still
or it fails before any live renderer starts. Selected stills always override
automatic generation.

An owned screenshot is written first to a unique private
`pluginDataDir()/staging` PNG. The capture helper then writes a temporary file
beside the final destination, validates its image signature (and full decode
when FFmpeg is present), and installs it atomically. Partial, stale, or
mismatched files are never promoted. Capturing an already running internal
Workshop item sequentially replaces only that exact owned child and restores
playback afterward when the request is still current; no foreign renderer is
inspected or signalled.

Pairs are stored both per output and by dynamic source identity. Revisiting a
video or Workshop ID reuses its verified still. The paired image remains the
real wallpaper seen by Noctalia, the lock screen fallback, wallpaper hooks,
overview/backdrop consumers, and compositor blur/xray integrations while the
live surface renders above it.

Schema 4 also keeps a reusable pairing catalog. A catalog item bundles media,
its selected/automatic still policy, and its theme once, then can be inserted
into multiple playlists. Playlist occurrences retain stable IDs and a validated
snapshot; editing a linked catalog item updates its occurrences, while deleting
the catalog item leaves existing playlist snapshots usable.

An explicit Noctalia lock-screen image still overrides the ordinary wallpaper;
Wall-in-One does not silently rewrite that setting.

## Per-entry Noctalia themes

The playlist entry editor defaults a new entry to an explicit adaptive policy:
`auto`, the `wallpaper` source, and the first available generator (falling back
to `m3-tonal-spot`). It can instead store dark/light/auto with a built-in,
community, custom, or wallpaper selection, or **Keep Current** through the
compatibility `inherit` policy. Direct Quick Choice and library-add/legacy
actions do not pretend to snapshot the current shell theme: they inherit unless
the compatibility color-sync setting requests the configured wallpaper
generator.

Wallpaper generators and the built-ins pinned from the `v5.0.0-beta.7` source
(project version `5.0.0`) are always available. A dedicated inventory service
also reads valid custom palette JSON
files from Noctalia's XDG config directory and refreshes the official community
catalog with a bounded six-hour TTL plus a last-known-good cache. It does not
poll repeatedly while the panel is open.

Adaptive palette previews are exact Noctalia CLI output, generated from the
pairing's selected or currently available still with
`noctalia theme <image> --scheme <scheme> --both -o <file>`. Preview generation
does not apply the theme. **Auto** shows both the dark and light surface plus
primary, secondary, tertiary, and error accents. An automatic-still pairing has
no adaptive preview until its representative has actually been captured. The
service hashes the still before cache lookup and again after generation. Its
16-entry memory cache is keyed by path, bounded metadata, SHA-256, and generator
scheme, so even a same-size rapid rewrite cannot silently reuse stale colors.

Application order is intentional: Wall-in-One first persists the static image,
then applies the entry's theme, then starts or replaces its owned live renderer.
This lets an entry override any theme preset associated with a native Noctalia
favorite. If a requested community/custom name is missing, Wall-in-One keeps
the requested value in the playlist, reports a degraded transition, and uses
`builtin/Noctalia` at runtime instead of silently rewriting user intent.

Noctalia has one palette for the shell, not one per output. **Global palette
leader output** selects which output may write it; a disconnected leader gets a
deterministic connected fallback until it returns. Without a configured leader,
the latest successful transition wins, and simultaneous due outputs are ordered
deterministically so only the final transition writes the palette.

The public `color-scheme-get` reply describes Noctalia's configured source and
selection, not proof that a community/custom file resolved successfully.
Likewise, `theme-mode-get` reports the resolved dark/light mode rather than the
configured `auto` token. Diagnostics therefore distinguish requested,
configured/assumed, fallback, and error state instead of claiming an
unobservable result.

A missing or unreadable local video degrades to its validated selected still or
cached automatic still and reports the live layer as unavailable. It blocks
before changing the backing only when no valid representative exists. If the
media and still are valid but the selected renderer command is missing or
startup fails, that representative remains visible and the live result is
reported as degraded.

## MotionBGS provider and fallback

MotionBGS does not publish a versioned API. Wall-in-One therefore treats its
integration as a fault-contained scraper:

- public, unauthenticated HTTPS pages only;
- serialized and rate-limited requests with bounded results and download size;
- same-origin detail/download URLs only;
- atomic local downloads plus a JSON source-metadata sidecar;
- no login automation, Cloudflare bypass, bulk crawling, or hidden endpoint
  discovery.

The provider reports a clear degraded state when its markup or response format
no longer matches. **Open MotionBGS** remains available independently, and
already downloaded files, stills, pairs, and playlists never depend on scraper
health.

The browser mirrors only routes the public site actually exposes. Text search
returns one unpaged site result set; adding a page parameter does not change
it. Latest, genre/tag, and 4K listings expose
validated previous/next links and currently contain 36 cards per page, so
Wall-in-One retains up to 48. The genre browser offers the site's current
top-level genres as presets while retaining a free-form tag slug for every
other public tag. HD is intentionally limited to page 1 because the
site currently redirects its advertised HD page 2 into the unfiltered global
catalog. MotionBGS exposes no stable combined genre-plus-resolution route.
Wall-in-One never bulk-crawls pages to manufacture missing search pagination.

The parsing design was independently implemented using the public site and the
factual route/selector profile in WaifuX revision
`ff44ecba11227ff965074ad3320096fa5827781c` as a compatibility reference.
WaifuX is GPL-3.0; no WaifuX implementation code is copied into this MIT
plugin. See [ADAPTERS.md](ADAPTERS.md) for provenance and the wire contract.

## Local libraries

The image and video roots are scanned non-recursively and may name the same
directory. PNG, JPEG, WebP, and AVIF entries appear under stills; MP4, MKV,
WebM, MOV, AVI, M4V, and GIF entries appear under videos. When both roots are
the same, an animated GIF appears only in the video section. User-root entries
are always read-only in the hub: they can be browsed, paired, and applied, but
never deleted there.

Wall-in-One creates two marked children beneath the image root:
`Wall-in-One/Wallhaven` and `Wall-in-One/Automatic Stills`. Only a direct child
with a valid adjacent Wall-in-One provider sidecar becomes managed and
deletable. Automatic stills receive a `.wall-in-one.json` sidecar when
generated. Native Wallhaven downloads receive a `.wallhaven.json` provenance
sidecar and are managed by Wall-in-One. Files downloaded by the separate
official Wallhaven plugin remain user-owned because that plugin chooses and
owns its own destination.

The native Wallhaven provider uses only `https://wallhaven.cc/api/v1` and
Wallhaven's documented CDN/thumbnail hosts. Searches accept the API's tag/query
syntax, every category and purity mask, sort/order, top-list range, minimum or
exact resolutions, ratios, color, and page. Previous/next navigation preserves
the returned seed for stable random pages. At most
24 results and 512 KiB of JSON are accepted per response, API requests are
serialized with a two-second minimum start interval, and downloads are capped
at 64 MiB. A download must be an exact current result, match its advertised
JPG/PNG type and size, and cannot overwrite an existing file or sidecar.

When MotionBGS is enabled and its local scraper requirements are usable, its
default cache is created as `Wall-in-One/MotionBGS` beneath the video root.
Downloads receive `.motionbgs.json` ownership/provenance sidecars and can be
browsed or deleted from the hub. If the integration is disabled or unavailable,
the default cache is not needed and the direct-site link remains. An advanced
explicit MotionBGS directory override is also supported.

Deleting a managed video through Wall-in-One removes its managed sidecar and
its managed automatic pair. It does not remove a manual/user still. Files that
disappear outside the hub are never treated as an instruction to delete a pair,
and Steam Workshop items remain Steam-owned and non-deletable.

Wallpaper Engine projects are discovered from the standard Steam, Flatpak
Steam, and Snap Steam Workshop cache locations, plus one optional custom
`content/431960` directory. Wall-in-One reads each bounded `project.json` and
its declared relative source/preview path; it does not read another Noctalia
plugin's private state. Scans are incremental (four candidates per service
tick), retain the previous completed list while running, cap candidate
enumeration, and run only at startup or after an explicit/configuration or
download change—not on every provider probe or output event.

Detected `awww`, legacy `swww`, `wpaperctl`, and `hyprctl` commands are reported
as diagnostics. They are foreign owners, so this staging build does not attach
to, signal, or terminate them.

## Plugin

Manifest ID: `goober/wall-in-one`.

| Entry | Manifest entry ID | Routed ID |
| --- | --- | --- |
| Service | `coordinator` | `goober/wall-in-one:coordinator` |
| Service | `renderer` | `goober/wall-in-one:renderer` |
| Service | `motionbgs` | `goober/wall-in-one:motionbgs` |
| Service | `palettes` | `goober/wall-in-one:palettes` |
| Service | `wallhaven` | `goober/wall-in-one:wallhaven` |
| Widget | `wall-in-one` | `goober/wall-in-one:wall-in-one` |
| Panel | `hub` | `goober/wall-in-one:hub` |
| Control Center shortcut | `wall-in-one-shortcut` | `goober/wall-in-one:wall-in-one-shortcut` |

Enable the plugin from this repository, then add the bar widget or optional
Control Center shortcut through Noctalia's editors.

Open the hub directly with:

```bash
noctalia msg panel-toggle goober/wall-in-one:hub
```

## Requirements

The manifest dependencies are `bash`, `curl`, and `sha256sum`. Noctalia treats
its dependency list as catalog metadata rather than an enable-time gate, so
Wall-in-One also probes each helper at runtime and degrades only the affected
capability.

Optional capabilities are detected at runtime:

- `ffmpeg` for video/animated-image still extraction and decode validation;
- `mpvpaper` for internal local-video playback (this is the only playback
  command Wall-in-One launches; a standalone `mpv` executable is not a separate
  readiness requirement);
- `linux-wallpaperengine` for internal Workshop playback and rendered capture;
- `socat`, or `nc` with Unix-socket `-U` plus either `-N` with `-w`, `-q`, or
  `--send-only`, for private mpvpaper IPC pause and audio control. Without a
  compatible client, pause/resume uses exact-PID signals;
  mute/volume is unavailable;
- `steam` or `xdg-open` for Wallpaper Engine library management; and
- `xdg-open` for the permanent MotionBGS browser fallback.

Wallhaven API/CDN requests and community-palette refreshes use the bundled
strict-origin `bounded-fetch` helper; MotionBGS remains isolated behind its own
same-origin transport. Missing transport tools, a site failure, or a parser
failure never disables local stills, local videos, Workshop projects, saved
pairs, or the direct MotionBGS browser fallback. See Noctalia's
[manifest dependency documentation](https://docs.noctalia.dev/v5/plugins/development/manifest/)
for the host's dependency model.

## Settings

Plugin-wide settings cover provider policy, image/video roots, capture and
pairing defaults, palette authority, renderer options, and defaults for new
playlists. The hub stores each reusable pairing, playlist, schedule, and screen
assignment in validated plugin data. The widget's glyph, label visibility,
label text, and color are per-placement settings in Noctalia's bar editor.

The optional **Wallhaven API key** setting is sent only in the `X-API-Key`
header and never embedded in a URL or status payload. Public SFW browsing works
without it; NSFW search is rejected locally unless a key is configured. The
key is a normal Noctalia plugin string setting and is not presented as encrypted
secret storage.

MotionBGS settings are deliberately small and bounded:

| Setting | Default | Boundary |
| --- | --- | --- |
| Use MotionBGS | on | Independently disables scraper commands without removing local downloads |
| Download directory | empty | Defaults to `Wall-in-One/MotionBGS` beneath an existing video root; an explicit override is accepted as-is |
| Preferred quality | HD | HD or 4K; a missing preferred variant is reported rather than silently substituted |
| Search/page result limit | 48 | 1–48; the default retains all 36 cards currently exposed by a MotionBGS catalog page |
| Cache lifetime | 30 minutes | 5–1,440 minutes |
| Maximum download | 256 MiB | 16–512 MiB |

The plugin's MIT license covers Wall-in-One code, not wallpapers discovered or
downloaded through MotionBGS. Each download gets a neighboring
`.motionbgs.json` sidecar containing its source page, resolved download URL,
quality, size, timestamp, and SHA-256 when available. That provenance record is
not a license grant; check the creator's terms before redistributing a file.
Native Wallhaven downloads follow the same principle: their `.wallhaven.json`
sidecar records origin and ownership for safe local management, not permission
to redistribute the artwork.

## Architecture

Noctalia loads each manifest entry into its own isolated `ScriptRuntime`. The
pinned v5 Luau surface has no supported `require` or shared-module loader, so an
entry cannot move ordinary helper functions into another `.luau` file and
import them. The coordinator and panel therefore remain self-contained entry
files; the renderer, MotionBGS, palette, and Wallhaven files are separate only
because each is an independently scheduled service communicating through
bounded, versioned state.

If Noctalia adds supported module imports, the safe in-process split boundaries
are library/config normalization, playlist and schedule execution, capture and
Workshop metadata, provider-download coordination, and IPC command dispatch.
Without module imports, a future service split is appropriate only when a
domain needs an independent lifecycle and a small explicit state protocol.
Turning synchronous helpers into services merely to reduce line counts would
add event-ordering and atomicity risks without reducing runtime coupling.

## Stored state and upgrades

`config.json` schema 4 stores gesture mappings, the reusable pairing catalog,
named playlists, output fallback assignments, and list-ordered schedule rules
with explicit month and weekday filters. `runtime.json` schema 6 stores provider
observations, source-to-still capture provenance, independent
per-output/per-playlist run state, active schedule/manual-pin state, palette
authority/application diagnostics, and the bounded `current_workshops` map
derived from exact owned renderer status. Cursor, history, and shuffle bags use
stable entry IDs, so reorder and deletion do not retarget a run by accident.

The retained `cycle_*` setting and action identifiers are compatibility names
from the earlier mixed-cycle model. The v0.5 interface and executor treat them
as playlist defaults or playlist actions; they do not select a second scheduling
engine.

Supported schema-1–3 config and schema-1–5 runtime state are fully validated
before a recoverable two-document migration installs either replacement. A
transaction journal and last-known-good backups repair interruption between the
two file renames. Unknown or corrupt schemas fail closed and remain visible in
Diagnostics. Each document is limited to 8 MiB before decoding, and nested maps,
paths, histories, schedules, and collections are normalized to the same bounds
enforced at runtime.

## Current testing boundary

The renderer supervisor protocol, nonce rejection, exact-PID cleanup, native
Wallpaper Engine screenshot flow, static pairing, schema migration, library
scans, playlist/schedule commands, and manifest contract belong in the
repository and NixOS VM gates. The current schema-4/6, palette, native
Wallhaven, and managed-MotionBGS tree passes the complete offline contract and
full five-service NixOS VM gate. It is ready for a disposable live-desktop test,
not yet for an unattended daily-driver session.
A VM can validate argv, staging,
fallback, coexistence, exact replacement ownership, and teardown, but not the
visual result, GPU rendering, audio playback, compositor layer ordering, or
actual shell-theme propagation. Those still require a disposable desktop test.

```bash
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
nix build -L path:.#vm-test-wall-in-one
```

See [ADAPTERS.md](ADAPTERS.md) for provider and state protocols,
[TESTING.md](TESTING.md) for automated coverage, and
[`tests/manual/wall-in-one.md`](../tests/manual/wall-in-one.md) for the manual
desktop matrix.
