# Wall-in-One

Wall-in-One `0.4.0` is a Noctalia v5 wallpaper hub for still images, local
videos, and Wallpaper Engine Workshop projects. It keeps one real Noctalia
wallpaper paired with every live source, exposes Noctalia's palette controls,
and runs one persistent mixed cycle per output.

The target remains Noctalia `5.0.0-beta.7`, plugin API `17`.

## What the hub owns

Wall-in-One has five coordinated layers:

1. **Noctalia static wallpapers and colors.** Open the built-in wallpaper
   selector, use next/previous/random, persist stills with `setWallpaper`, and
   optionally select Noctalia's wallpaper color source and Material scheme.
2. **Wallhaven.** Open the official `noctalia/wallhaven:browser`, which already
   provides API-key support, search, filters, download, save, and apply.
3. **MotionBGS and local video.** Search the public MotionBGS site through a
   bounded best-effort HTML provider, download an item into the configured
   video library, generate a still with FFmpeg, and play it through an
   internally owned mpvpaper process. A direct **Open MotionBGS** link is always
   retained if the site's markup changes or the scraper is unavailable.
4. **Wallpaper Engine.** Scan Steam's ordinary Workshop `content/431960`
   cache, show installed projects, create a representative still from their
   source video or preview, and apply a numeric item through an internally
   owned `linux-wallpaperengine` process.
5. **One scheduler.** Each output gets a saved sequence containing any mix of
   static paths, local video paths, and Workshop IDs. The hub supports
   sequential, shuffle-bag, and random order; per-output interval; start,
   stop, pause, resume, next, previous, and random controls; and optional
   resume on plugin load.

The bar widget retains Noctalia's searchable glyph selector, label toggle,
theme-token color, and independent left/middle/right action mappings. The
Control Center shortcut uses the same singleton coordinator.

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
disable the external plugin first. The independent **Use detected** toggles
default on and can force off Wall-in-One's Wallhaven, W Engine, mpvpaper, or
custom-panel integration without disabling or killing another plugin.

One API-17 renderer service owns one cancellable Bash supervisor with
`runStream`. Every `mpvpaper` or `linux-wallpaperengine` process remains a
foreground child in that process group. The supervisor tracks exact child
PIDs, and Noctalia terminates the entire group on plugin reload, disable, or
shutdown. It does not use `pgrep`, `pkill`, detached systemd scopes, or a
foreign PID file.

Internally owned live surfaces use the `bottom` layer. Noctalia's ordinary
static wallpaper surface remains enabled. This is deliberate: API 17 invokes
`onExit`, but teardown currently discards queued wallpaper restoration side
effects. A background-layer takeover cannot guarantee restoration during hot
reload, whereas a bottom-layer child disappears safely with its owner process.

## Static pairs and generated stills

Every live apply first resolves a static pair:

- Local videos use FFmpeg at the configured timestamp.
- Wallpaper Engine video projects use their source video.
- Scene and web projects use the Workshop preview when an owned rendered
  screenshot is not available.
- A manually selected durable image can be validated and paired directly.

The current output's selected static backing is also the explicit pairing
source for the next video or Workshop apply. Library and MotionBGS **Apply** or
**Add to cycle** actions copy that still path into the dynamic entry, so a
chosen Noctalia/static image remains bound to that live source across reloads.
If no still is selected, Wall-in-One generates one and caches its size and
modification-time fingerprint before reuse. Animated GIF backings are decoded
to a persistent PNG in the still directory so the paired artifact is truly
static; ordinary image selections continue to reference their durable source.

Leave **Still directory** empty to save generated frames in Noctalia's
configured wallpaper directory. An explicit directory must be absolute. The
capture helper writes a temporary file beside the destination, validates its
image signature (and full decode when FFmpeg is present), then installs it
atomically. Partial or mismatched files are never promoted.

Pairs are stored both per output and by dynamic source identity. Revisiting a
video or Workshop ID reuses its verified still. The paired image remains the
real wallpaper seen by Noctalia, the lock screen fallback, wallpaper hooks,
overview/backdrop consumers, and compositor blur/xray integrations while the
live surface renders above it.

An explicit Noctalia lock-screen image still overrides the ordinary wallpaper;
Wall-in-One does not silently rewrite that setting.

## Color synchronization

Color synchronization is independent of live playback. When enabled,
Wall-in-One sets Noctalia's global color source to `wallpaper` and applies the
selected scheme after pairing. Noctalia has one palette for the shell, not one
per output. **Global palette leader output** selects the pair reapplied last;
without it, the most recently paired output wins.

Turning Wall-in-One color sync off does not freeze a palette that Noctalia is
already deriving from `wallpaper`; applying a new static pair may still cause
Noctalia itself to regenerate it.

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
already downloaded files, stills, pairs, and cycles never depend on scraper
health.

The parsing design was independently implemented using the public site and the
factual route/selector profile in WaifuX revision
`ff44ecba11227ff965074ad3320096fa5827781c` as a compatibility reference.
WaifuX is GPL-3.0; no WaifuX implementation code is copied into this MIT
plugin. See [ADAPTERS.md](ADAPTERS.md) for provenance and the wire contract.

## Local libraries

**Video library directory** is scanned non-recursively for MP4, MKV, WebM,
MOV, AVI, M4V, and GIF files. The dedicated MotionBGS download directory falls
back to that configured video directory; downloads are rejected until one of
those two existing directories is selected. When no video directory is
configured, local scanning alone falls back to the still directory.

Wallpaper Engine projects are discovered from the standard Steam, Flatpak
Steam, and Snap Steam Workshop cache locations, plus one optional custom
`content/431960` directory. Wall-in-One reads each bounded `project.json` and
its declared relative source/preview path; it does not read another Noctalia
plugin's private state. Scans are incremental (four candidates per service
tick), retain the previous completed list while running, cap candidate
enumeration, and run only at startup or after an explicit/configuration or
download change—not on every provider probe or output event.

Detected `awww`, legacy `swww`, `wpaperctl`, and `hyprctl` commands are reported
as diagnostics. They are foreign owners, so this release does not attach to,
signal, or terminate them.

## Installation and IDs

Enable `goober/wall-in-one` from this repository, then add either UI surface:

- bar widget: `goober/wall-in-one:wall-in-one`
- Control Center shortcut: `goober/wall-in-one:wall-in-one-shortcut`
- attached hub: `goober/wall-in-one:hub`
- coordinator service: `goober/wall-in-one:coordinator`
- internal renderer owner: `goober/wall-in-one:renderer`
- MotionBGS provider: `goober/wall-in-one:motionbgs`

Open the hub directly with:

```bash
noctalia msg panel-toggle goober/wall-in-one:hub
```

Optional capabilities are detected at runtime:

- `ffmpeg` for video/animated-image still extraction and decode validation;
- `mpvpaper` for internal local-video playback;
- `linux-wallpaperengine` for internal Workshop playback;
- `xdg-open` for the permanent MotionBGS browser fallback.

Bash is the only manifest dependency. Optional `curl` is isolated to the
bounded MotionBGS transport helper; when it is missing—or when the site or
parser fails—local stills, local videos, Workshop projects, saved pairs, and
the direct browser fallback remain available.

MotionBGS settings are deliberately small and bounded:

| Setting | Default | Boundary |
| --- | --- | --- |
| Use MotionBGS | on | Independently disables scraper commands without removing local downloads |
| Download directory | empty | Falls back to the video-library directory; the selected directory must already exist |
| Preferred quality | HD | HD or 4K; a missing preferred variant is reported rather than silently substituted |
| Search result limit | 24 | 1–24 |
| Cache lifetime | 30 minutes | 5–1,440 minutes |
| Maximum download | 256 MiB | 16–512 MiB |

The plugin's MIT license covers Wall-in-One code, not wallpapers discovered or
downloaded through MotionBGS. Each download gets a neighboring
`.motionbgs.json` sidecar containing its source page, resolved download URL,
quality, size, timestamp, and SHA-256 when available. That provenance record is
not a license grant; check the creator's terms before redistributing a file.

## Stored state and upgrades

`config.json` schema 2 stores gesture mappings and per-output cycle entries.
`runtime.json` schema 3 stores provider observations, source-to-still pairs,
and cycle execution state including the absolute next-due timestamp. Supported
older schemas migrate atomically, retaining a last-known-good backup. Unknown
or corrupt schemas fail closed and appear in Diagnostics. Each document is
limited to 8 MiB before decoding; nested output maps, pair registries, paths,
cycle history, and shuffle bags are normalized to the same bounds enforced at
runtime, so a current-version number alone cannot bypass validation.

## Current testing boundary

The renderer supervisor protocol, nonce rejection, exact-PID cleanup, static
pairing, persistence, library scans, scheduler commands, and manifest contract
are covered by repository checks and the NixOS VM harness. This workstation
has `linux-wallpaperengine` and FFmpeg, but not mpvpaper, so real mpvpaper
launch/render behavior must still be exercised by the user. MotionBGS parsing
is inherently best effort and is tested against bounded captured fixtures plus
a deliberately optional live smoke test.

```bash
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
nix build -L .#vm-test-wall-in-one
```

See [TESTING.md](TESTING.md) and
[`tests/manual/wall-in-one.md`](../tests/manual/wall-in-one.md) for the manual
matrix.
