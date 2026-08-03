# Wall-in-One provider adapters

Wall-in-One `0.5.0` separates four integration boundaries: Noctalia's native
wallpaper/theme APIs, Wall-in-One's own provider services, public interfaces
exposed by other Noctalia plugins, and processes owned directly by Wall-in-One.
External plugins are discovered with `noctalia msg plugins list` and are
contacted only through public panels or documented service events. Noctalia v5
does not expose another plugin's private state, so enabled, available, and ready
are deliberately separate states.

## Built-in provider registry

| Provider | Public integration |
| --- | --- |
| Noctalia | Wallpaper panel and `wallpaper-next`, `wallpaper-previous`, and `wallpaper-random` |
| Wallhaven | Wall-in-One's bounded official-API search/detail/download service; optional `noctalia/wallhaven:browser` panel and independent `https://wallhaven.cc/` link fallbacks |
| W Engine | Panel plus `next`, `cycle-stop`, and `stop` on `tadomika_ari/w-engine:start` |
| mpvpaper | Picker plus `pause`, `resume`, `toggle`, `clear`, and `clear-all` on `noctalia/mpvpaper:service` |
| MotionBGS | Wall-in-One's bounded text-search and pageable latest/genre/4K public-page service plus an independent direct-site link |
| Custom | A user-configured full `author/plugin:panel` ID, open-only |

The current external W Engine and mpvpaper releases do not publicly report the
active source or return data from their service IPC. Wall-in-One therefore
never reads their private state, PID files, process arguments, or caches.
`auto` backend mode prefers one of those enabled external owners. `external`
mode requires it. `internal` mode is available only after the matching external
plugin is disabled; it lets Wall-in-One start its own `mpvpaper` or
`linux-wallpaperengine` child and apply a source directly. An independently
disabled provider toggle overrides all three modes without disabling the other
plugin or killing a foreign process. Wallhaven's native service is independent
of the separate official plugin and is controlled by the same default-on
integration toggle; disabling it does not disable or uninstall that plugin.

## Coordinator state protocol v4

The coordinator keeps its frequently observed lifecycle state small. Protocol 4
publishes `wall_in_one_status` with the service instance and sequence, storage
health, provider readiness, active captures, normalized plugin settings, and
revision references to three heavier domains. The bar widget and Control Center
shortcut consume only this lifecycle object.

The attached hub reconstructs its detailed view from protocol-1 domain snapshots
whose `instance_id` matches the lifecycle object:

| State key | Contents |
| --- | --- |
| `wall_in_one_config_state_v1` | validated pairing catalog, playlists, output assignments/playback overrides, schedules, and gestures |
| `wall_in_one_runtime_state_v1` | pairs, playlist runs, output state, palette diagnostics, active Workshop IDs, and last capture |
| `wall_in_one_library_state_v1` | bounded still, video, and Workshop inventories plus scan state |

The coordinator publishes a changed domain before the lifecycle revision that
advertises it. The panel rejects stale revisions and snapshots from another
service instance, then also reads the renderer, palette, Wallhaven, and
MotionBGS services from their own versioned keys. This split avoids repeatedly
republishing the complete playlist and library documents during ordinary status
changes; it is an observation protocol, not a retry or command-delivery channel.
Heavy domains publish only after their owning mutation path marks them dirty;
they are not recursively re-signed inside Noctalia's bounded callback. The small
lifecycle object retains exact native-JSON delta suppression. Settings edits
update that bounded lifecycle object without reserializing the unchanged pairing
and playlist catalog. Media/Workshop directory changes alone queue a library
rebuild for the next service update; unrelated integration, playback, palette,
and gesture settings do not rescan the filesystem inside `onConfigChanged`.

## Schema-4 pairing, playlist, and screen model

`config.json` schema 4 owns a bounded reusable `pairings` catalog. Each pairing
bundles optional dynamic media, a selected/automatic still policy, and a theme
policy. A playlist occurrence has its own stable entry ID and retains a
validated bundle snapshot plus an optional `pairing_id` link. Editing a linked
catalog item synchronizes those occurrence snapshots. Deleting a catalog card
only detaches its occurrences and preserves their last valid snapshots; it does
not delete an occurrence, user media, or a user-selected still.

The panel separates catalog cards into still, video, and Wallpaper Engine
drawers. API-17 `ui.dragSource`/`ui.dropZone` supports panel-local pointer drops
into playlists and pointer reordering within them. **Add to playlist** and
explicit move-up/move-down buttons are equivalent fallbacks for keyboard use,
unsupported drag paths, and precise placement. Both paths send the same
validated coordinator commands; drag payloads never carry trusted filesystem
or deletion authority.

Each screen stores one fallback playlist and an ordered array of optional
calendar rules. Rules include non-empty month and weekday sets plus an all-day
or bounded time window. Matching walks the visible top-to-bottom list and the
lowest active row wins, including overnight ranges whose origin may be in the
previous weekday or month. Manual selection pins the screen until schedule
resume.

Screen playback can inherit the selected playlist's rotate/shuffle order and
time-per-swap or store its own `order` and `interval_seconds`. Effective values
resolve screen override, then playlist default, then global compatibility
setting. The override applies whichever fallback or scheduled playlist becomes
active on that screen; clearing it restores inheritance without rewriting the
playlist or another screen's independent run state.

Schema 3 is accepted only as migration input. Migration derives reusable
pairing records from its entry bundles, retains validated occurrence snapshots,
expands an omitted month filter to all twelve months, and preserves the old
schedule array as schema 4's explicit list precedence.

The internal Wallpaper Engine library scans Steam's ordinary
`steamapps/workshop/content/431960` directories and an optional user-selected
directory. That is the user's installed Workshop cache, not a Noctalia
plugin-private cache. Relative paths read from `project.json` remain contained
inside the numeric item directory. Wall-in-One keeps the numeric Workshop ID
as the stable library/pair identity, but passes the discovered absolute project
directory to current `linux-wallpaperengine` builds. It falls back to the
numeric ID only when no validated local project directory is available.

W Engine `1.1.0` does accept an `apply` request containing a numeric Workshop
ID from its own panel, but that request travels over W Engine's plugin-scoped
state. Noctalia does not expose it across plugin IDs, and W Engine's documented
IPC only contains `next`, `cycle-stop`, and `stop`. Wall-in-One must therefore
not write `w_engine_request` or claim apply-by-ID support. A future adapter can
advertise an `apply` capability and expose a reviewed `apply-v1` service event
that validates the connector and numeric ID before handing the request to W
Engine's existing owner service.

W Engine also already sets a representative Workshop preview or cached video
frame as Noctalia's wallpaper when its color-sync setting is enabled. The
Wall-in-One **Export current Noctalia backing** action reads that public
`wallpaper-get` result and copies it through Wall-in-One's validator; it does
not inspect W Engine's private `frames` or `thumbs` layout.

## Internally owned renderer and capture

Internal mode is a separate boundary from the external W Engine adapter. It is
available only when enabled-plugin discovery succeeds, no external owner is
enabled, and `linux-wallpaperengine` is installed. Wall-in-One passes only the
validated `background` or `bottom` layer selected in plugin settings. `bottom`
remains the portable default; `background` is intended for compositor-specific
arrangements such as niri's `place-within-backdrop` rule. Wallpaper Engine uses
`background` only when the installed command advertises `--layer`; a legacy
build is limited to `bottom`. The same setting is used for internally owned
mpvpaper children.

An internal Workshop start records its numeric ID and layer in renderer status.
The coordinator derives schema-6 `runtime.json.current_workshops` from exact
running or paused W Engine children, bounded to the known per-output limits.
This is active ownership state, not external-provider observation or a restart
playlist: capture temporarily clears it, and stop, exit, ownership loss, or
service teardown removes it.

For native rendered capture, the coordinator creates one unique
`pluginDataDir()/staging/capture-*.png` path and sends a `capture_w_engine`
command through the existing nonce-checked renderer channel. The supervisor
sequentially replaces only Wall-in-One's child for that output and launches
`linux-wallpaperengine` with the exact output, validated discovered project
directory (or numeric-ID fallback), layer, validated render options,
`--screenshot`, and a `--screenshot-delay` clamped to
linux-wallpaperengine's upstream one-to-five-frame range. It never starts a
second concurrent child for that output or signals a foreign process.

The supervisor accepts the artifact only after it is non-empty, stable, and no
longer held open by the exact child, terminates the one-shot renderer, and
returns completion through the owned status protocol. The coordinator then
signature-validates the PNG, performs a full decode when FFmpeg is available,
atomically installs an automatic result in the managed Automatic Stills
directory (or a manual export in the image root), and records capture method
`linux-wallpaperengine-fbo-v1`.
When the request remains current it can pair the result through Noctalia and,
if capture displaced a live owned child, restore that exact Workshop item.
Failure, timeout, cancellation, output removal, or backend-generation change
cannot promote a stale pair or launch delayed playback. A valid source-video or
Workshop-preview still remains the fallback when native capture cannot finish.
When a different Workshop or mpvpaper child already owns the output,
Wall-in-One resolves that non-destructive fallback before replacing playback;
a failed still therefore leaves the unrelated owned child running.

### Coexistence, hot-swap, and controls

`mpvpaper` and `linux-wallpaperengine` may be installed and used on the same
system. Different outputs may run different Wall-in-One-owned backends at the
same time. On one output, Wall-in-One deliberately owns at most one dynamic
child: switching between video and Wallpaper Engine first stops the exact old
child and then starts the replacement. It never relies on two same-output
layer-shell surfaces having deterministic stacking. This is break-before-make,
not gapless, and a failed replacement does not automatically restart the old
source.

An unexpected exit after the supervisor's startup acknowledgement is different
from a synchronous replacement failure. For an armed multi-entry playlist the
coordinator advances only after a transient, per-output exponential delay of
10, 20, 40, 80, 160, and then at most 300 seconds. The sequence resets after
the acknowledged replacement actually survives for 60 seconds, and is cleared
by an explicit playlist/output intent. It is deliberately not persisted across
plugin loads.

That guarantee applies only to the internal supervisor. External W Engine and
mpvpaper plugins can coexist as installed plugins, but their public APIs do not
offer a common ownership/handoff transaction. Wall-in-One therefore does not
signal or kill their processes. `auto` selects an enabled external owner;
`internal` remains fail-closed until that matching provider plugin is disabled.
Because ownership policy is provider-specific, an externally started provider
of one type can still overlap the other type on the same output; Wall-in-One
does not claim system-wide exclusion for foreign processes.

Internal mpvpaper requires the `mpvpaper` command; Wall-in-One does not require
or launch a separate `mpv` executable. It always exposes stop and exact-PID
signal fallback for pause, resume, and toggle. Private IPC pause plus mute,
unmute, toggle-mute, and volume additionally require `socat`, or `nc` with
Unix-socket `-U` plus either `-N` with `-w`, `-q`, or `--send-only`. Internal
Wallpaper Engine exposes stop and signal-based pause, resume, and toggle.
Current `linux-wallpaperengine` does not expose equivalent runtime audio IPC,
so Wallpaper Engine mute/volume commands are not advertised.

Every user action writes one command with a monotonic nonce. Acknowledgements
report completion or failure; they do not trigger retransmission. The
coordinator's two-second `state.get` read only repairs lifecycle/status
convergence and does not publish another command. Renderer status is published
for real transitions, pending-write acknowledgement, or recovery; five-second
supervisor heartbeats do not create unchanged state-bus updates. The internal
64-command renderer queue is a defensive burst bound, not an expected working
depth or a limit on installed plugins/outputs.

## Library storage and ownership

The image and video roots are user-selected and may be the same directory.
Wall-in-One scans them non-recursively and classifies supported files by media
type; when the roots match, GIF is listed only as video. Files directly in
either root are user-owned and never receive a delete action in the hub.

Default managed locations are:

- `<image root>/Wall-in-One/Wallhaven` — Wall-in-One's native provider installs
  validated JPG/PNG results here with adjacent `.wallhaven.json` provenance and
  ownership records. Downloads made by the separate official Wallhaven plugin
  remain user-owned because they do not carry this service's sidecar.
- `<image root>/Wall-in-One/Automatic Stills` — default-on video and Workshop
  representatives, each with a `.wall-in-one.json` ownership/pair sidecar.
- `<video root>/Wall-in-One/MotionBGS` — created when MotionBGS is enabled and
  its local helper requirements are usable; each download has an adjacent
  `.motionbgs.json` sidecar. An explicit download-directory override is used as
  selected instead of this default child.

Manual still exports go directly to the image root and remain user-owned. A
file becomes deletable only when it is a direct child of the expected managed
directory and its adjacent sidecar validates. When the user explicitly deletes
a managed MotionBGS video in the hub, Wall-in-One also deletes that video's
managed automatic still. A native Wallhaven file is deletable only as the exact
direct child proven by its matching sidecar. Wall-in-One never deletes a manual
still, and external file disappearance or a Steam Workshop unsubscribe does not
trigger orphan cleanup.

## Noctalia palette inventory v1

The `palettes` service discovers choices but never changes the active shell
theme. The coordinator remains the sole entry executor and applies an entry in
the order static wallpaper, theme mode, palette, then dynamic renderer.

The service publishes `wall_in_one_palettes_status_v1` and accepts only a newer
schema-1 `refresh` or `preview` command on
`wall_in_one_palettes_command_v1`. Built-in names and wallpaper generators are
pinned from Noctalia tag `v5.0.0-beta.7` (project version `5.0.0`).
Custom choices are valid bounded JSON files under Noctalia's XDG
`noctalia/palettes` directory. Community choices come from
`https://api.noctalia.dev/palettes`, with a six-hour TTL, a two-MiB
response/cache limit, at most 512 normalized entries, and a last-known-good
primary/backup cache. Startup performs one TTL-gated refresh; opening the panel
does not create a periodic network poller.

A preview request carries a bounded correlation key, a safe absolute path to
the pairing's selected or currently available real still, and one pinned
wallpaper generator scheme. The service runs exactly
`noctalia theme <image> --scheme <scheme> --both -o <file>` against a private
temporary JSON path. This command only calculates colors; the palette service
does not apply theme mode, palette selection, or wallpaper state. Automatic
still mode remains preview-unavailable until capture has produced a validated
representative.

`status.preview` reports `idle`, `loading`, `ready`, or `error` with the request
key, path, scheme, source fingerprint, bounded diagnostic, and normalized
result. The result contains dark and light surface plus primary, secondary,
tertiary, and error accents, so **Auto** can display both variants and explicit
dark/light can select one without recomputation. Source path, size, mtime, and
scheme form the cache identity. The service keeps at most 16 results in memory,
serializes one CLI operation, retains only the latest pending request, rejects
stale callbacks by generation, caps output at 512 KiB, and removes its private
files on every terminal path.

On shutdown the service retains the complete v1 status shape but publishes a
bounded terminal snapshot: `ready=false`, `last_event=stopped`, an idle preview,
an unavailable cache, zero counts, and empty catalogs. It deliberately does not
re-sign or copy the discovered palette lists inside Noctalia's exit callback.

Community refreshes use the bundled `scripts/bounded-fetch` transport with the
exact catalog URL, redirects disabled, curl configuration disabled, a private
temporary response under `RLIMIT_FSIZE`, JSON content-type enforcement, and
atomic no-replace installation. The Luau service rechecks the exact byte count
before decoding and owns cancellation through a short-lived private guard.

Noctalia's public theme IPC does not expose the full installed palette inventory,
so this service is intentionally separate. It also cannot prove that a
community/custom selection resolved after `color-scheme-set`: the corresponding
getter reports configured source/name, and `theme-mode-get` returns resolved
dark/light rather than the configured `auto` token. Coordinator diagnostics
must therefore describe requested and configured/assumed state, preserve a
missing request, and use `builtin/Noctalia` as a visible runtime fallback.

Noctalia has one global theme. A configured palette-leader output is the sole
writer; otherwise the latest successful transition wins. When outputs become
due together, the coordinator processes them deterministically and authorizes
only the final transition to write the palette. These controls cannot coordinate
Noctalia's separate native slideshow because v5 exposes no public pause/disable
API for it; users must disable native wallpaper automation on outputs governed
by Wall-in-One schedules.

## Wallhaven official-API provider v1

The `wallhaven` service uses only Wallhaven's documented
`https://wallhaven.cc/api/v1` routes and validated Wallhaven CDN/thumbnail
origins. It accepts schema-1 monotonic commands on
`wall_in_one_wallhaven_command_v1` and publishes delta-suppressed lifecycle
state plus bounded results on `wall_in_one_wallhaven_status_v1` and
`wall_in_one_wallhaven_results_v1`.

Supported actions are `search`, `detail`, `download`, and `clear`. Search
accepts query, three-bit category/purity masks, documented sort/order and
top-list-range values, minimum or exact resolutions, up to eight ratios, one
documented color, and a bounded page number. Stable random pagination carries
Wallhaven's returned six-character seed. It normalizes at most 24 results from
a response no larger than 512 KiB,
serializes operations, and requires two seconds between API request starts.
Public SFW search works without authentication. The optional API key is locally
validated, sent only as `X-API-Key`, never placed in a URL/status payload, and
required before an NSFW purity bit is accepted.

API and CDN ingress use the bundled `scripts/bounded-fetch` transport. Each
profile accepts only its closed HTTPS route grammar, disables redirects and
ambient curl configuration, applies deadline/speed/file-size limits, verifies
content type (plus media signature), and installs a private response without
overwriting. An API key is passed through a one-line mode-`0600` header file in
the response directory, never in process arguments; the helper removes that
file and the cancellation guard on every exit.

Detail accepts only an ID from the current result set. Download likewise accepts
only that result's exact CDN or short URL; the provider then uses the normalized
CDN URL, caps the file at 64 MiB, checks advertised size and JPG/PNG signature,
and refuses every overwrite. It stages the image and a `.wallhaven.json`
provenance record in the coordinator-created managed directory and promotes
both, removing the image if sidecar installation fails. The provider does not
make deletion decisions; the coordinator must revalidate the direct managed
child and matching sidecar before offering delete.

The sidecar records source and local ownership boundaries; it is not a license
grant. Wall-in-One's MIT license does not cover downloaded wallpaper media, and
users remain responsible for the creator/site terms governing redistribution.

The optional `noctalia/wallhaven:browser` panel remains a separate fallback.
Its files are not treated as Wall-in-One-managed because inter-plugin state and
download ownership are not public in Noctalia v5.

The coordinator also owns an unconditional **Open wallhaven.cc** fallback to
`https://wallhaven.cc/` whenever a desktop URL opener is available. It remains
independent of API health, authentication, parser results, the native-service
toggle, and the optional official plugin. If the opener is unavailable, the
panel reports that limitation instead of hiding the site destination.

## MotionBGS public-page adapter v1

MotionBGS does not publish a stable, versioned API. The `motionbgs` service is
therefore an unofficial, best-effort public-page adapter, not an assertion of
partnership or API compatibility. It recognizes only these same-origin routes:

- `/search?q=<query>` for one bounded, unpaged text-search result set;
- `/tag:<slug>/[page/]` for pageable genre/tag listings;
- `/4k/[page/]` for pageable 4K listings;
- `/hd/` for the first HD listing page only;
- `/<slug>` for one wallpaper detail page; and
- `/dl/hd/<numeric-id>/` or `/dl/4k/<numeric-id>/` for the selected MP4.

These modes are separate because MotionBGS exposes no stable combined
genre-plus-resolution route. Its text-search page has no previous/next links
and ignores a page parameter. Genre/tag and 4K pages do expose same-family
pagination; the service verifies those links and the final effective route.
The site's advertised `/hd/2/` currently redirects to unfiltered `/2/`, so the
adapter rejects HD pages after the first rather than presenting mislabeled
results. It does not crawl unrelated pages to emulate missing search behavior.

The parser looks for wallpaper-card anchors, `span.ttl` titles, same-origin
images, and HD/4K download anchors. Unknown markup fails closed with a visible
`site-markup` status. An anti-bot challenge similarly reports `challenge`; the
helper does not solve, evade, or retry around it. The direct
<https://motionbgs.com/> action is owned by the coordinator and remains
available whenever `xdg-open` exists, even if the scraper is disabled or
broken.

Network transport is isolated in `scripts/motionbgs-provider`. It performs
public HTTPS GETs with a named Wall-in-One user agent and has the following
fixed safeguards:

- ambient curl configuration disabled before the helper's explicit redirect
  loop and same-origin validation;
- one serialized request queue, one-second spacing, and at most eight queued
  operations;
- at most 48 results, 80 query bytes, eight cached listing pages, and 48 cached
  detail records;
- listing HTML is parsed incrementally one anchor per service tick, then
  published atomically, so a complete 36-card page stays within Noctalia's
  per-callback CPU budget;
- one-MiB HTML responses, a 20-second HTML deadline, at most three redirects,
  and redirects that must stay on `https://motionbgs.com`;
- download limits configurable only from 16 to 512 MiB, with a 45-second
  transport deadline and 60-second service-process watchdog, an MP4 content
  type/signature check, and no partial file promotion; and
- no scripts, cookies, authentication, browser automation, hidden endpoints,
  challenge bypass, cross-origin URLs, or bulk crawl.

Search/detail cache lifetime is configurable from 5 to 1,440 minutes. Cache
updates and downloads are written beside their destination and renamed into
place. A completed video receives a neighboring `.motionbgs.json` sidecar with
schema, provider, title, source page, resolved download URL, quality, content
type, byte count, UTC download time, and a SHA-256 digest when `sha256sum` is
available.

### Service state contract

The API-17 service communicates with the panel through plugin-scoped Noctalia
state. All payloads use schema `1` and a strictly increasing positive integer
nonce:

| State key | Purpose |
| --- | --- |
| `wall_in_one_motionbgs_command_v1` | `search`, `details`, `download`, or `clear` request |
| `wall_in_one_motionbgs_command_ack_v1` | accepted/complete/error acknowledgement |
| `wall_in_one_motionbgs_status_v1` | readiness, queue, last request/download, and degraded-state detail |
| `wall_in_one_motionbgs_results_v1` | current search results and selected detail |

The helper's stdout contract is one tab-delimited line. Successful operations
return `WIO-MBG1`, `ok`, HTTP status, effective URL, content type, byte count,
and installed path. Failures return `WIO-MBG1`, `error`, a bounded error kind,
and bounded detail. Luau rejects a cross-origin effective URL or a response
path different from the exact path it supplied.

### Provenance, licenses, and user responsibility

The route and selector compatibility research was cross-checked against the
public data-source profile in
[WaifuX revision `ff44ecba`](https://github.com/jipika/WaifuX/tree/ff44ecba11227ff965074ad3320096fa5827781c).
WaifuX is GPL-3.0. Wall-in-One's parser and transport were independently
implemented; no WaifuX source code was copied into this MIT plugin.

The Wall-in-One license applies only to this plugin's code. MotionBGS pages and
wallpaper files can have separate creator, site, or Workshop rights. The JSON
sidecar preserves source facts but does not grant a license. Users must verify
the applicable terms before reuse or redistribution, and should stop using the
adapter if the site withdraws public access or disallows this access pattern.

## W Engine cooperation protocol v1

This optional protocol lets a future W Engine release or reviewed fork remain
the sole `linux-wallpaperengine` owner while Wall-in-One coordinates pairing.
Fields inside each payload are tab-separated. Connector names and Workshop IDs
must not contain tabs. The requested path is an opaque, unique staging path;
the provider must return that exact path and no other file location.

W Engine announces capabilities to Wall-in-One:

```text
plugin goober/wall-in-one:coordinator all provider-capabilities-v1
payload: w_engine<TAB>1<TAB>status,capture
```

After every successful enabled-plugin discovery, Wall-in-One sends
`wall-in-one-probe-v1` to `tadomika_ari/w-engine:start`. A v1 adapter must
answer by re-sending `provider-capabilities-v1` and, when `status` is
advertised, its current output selections. If no fresh capability response
arrives within 10 seconds, Wall-in-One clears the stale adapter flags and
reported selections instead of treating old readiness as current.

While `status` is advertised, W Engine reports or clears an output selection:

```text
event: provider-current-v1
payload: w_engine<TAB><connector><TAB><workshop-id>
clear:  w_engine<TAB><connector><TAB>-
```

When `capture` is advertised and the user requests a rendered still,
Wall-in-One sends this event to `tadomika_ari/w-engine:start`:

```text
event: capture-v1
payload: <request-id><TAB><connector><TAB><workshop-id><TAB><staging.png><TAB><frame-delay>
```

`staging.png` is created beneath Wall-in-One's private
`pluginDataDir()/staging` directory and is unique to the request. The existing
setting keeps its default of 15 and 1–120-frame range for compatibility. A
cooperative adapter receives that full configured value; only Wall-in-One's
internally owned linux-wallpaperengine path clamps it to upstream's five-frame
maximum. W Engine must capture through its existing per-output renderer or
perform one controlled owner-managed restart. It must never run a concurrent
second renderer. Write through a provider-owned
temporary file, validate the PNG, atomically install it at the exact requested
staging path, then call back Wall-in-One:

```text
event: capture-result-v1
success payload: <request-id><TAB>ok<TAB><exact-staging-path>
failure payload: <request-id><TAB>error<TAB><bounded-detail>
```

Wall-in-One rejects mismatched paths, control characters, stale request IDs,
and missing results. It validates the returned image through its export helper,
copies automatic results into the managed Automatic Stills directory (manual
exports go to the image root), removes the private staging file, and optionally
persists the validated result through Noctalia's output-specific wallpaper
command. The deadline is the greater of 60
seconds or the configured frame delay plus 60 seconds. Failure and timeout
cleanup both drain any queued work for that output. Automatic capture and
pairing are on by default and react to internally applied sources or fresh
adapter-reported status; the user can explicitly disable that policy.

Rendered adapter capture requires the optional `ffmpeg` command for full PNG
decode validation. Without it, Wall-in-One does not weaken the exact-path
contract; it falls back to the Workshop source/preview path. Static preview
copies and manual static pairing still use signature validation without
`ffmpeg`.

Without this handshake, external mode still supports safe fallback from a
configured Workshop ID: video projects use FFmpeg to export a real frame, while
scene and web projects copy or decode their Workshop preview. This is a
representative static pair, not a claim that the external renderer's current
framebuffer was captured. Internal mode instead attempts the owned native
screenshot path above before using the same fallback.
