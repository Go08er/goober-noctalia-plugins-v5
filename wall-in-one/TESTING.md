# Wall-in-One test record

Target: Wall-in-One `0.5.0`, Noctalia tag `v5.0.0-beta.7`
(project/runtime version `5.0.0`), plugin API 17.

## Automated checks

Run from the repository root:

```bash
python3 tools/validate.py
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
bash wall-in-one/scripts/bounded-fetch self-test
bash wall-in-one/scripts/motionbgs-provider self-test
nix build -L path:.#vm-test-wall-in-one
```

The explicit `path:.` source includes newly created, not-yet-committed service
files in staging-tree tests. The ordinary `.#...` Git-flake form intentionally
omits untracked files and can therefore test an incomplete plugin manifest.

The current manifest has five services: coordinator, renderer, MotionBGS,
palette inventory, and native Wallhaven. Repository validation and the contract
test must cover all five plus panel/widget/shortcut entry points, translation
keys, helper permissions, schema-4/6 persistence, playlist/schedule behavior,
static/theme ordering, renderer ownership, and both online-provider boundaries.
The NixOS VM supplies fake commands and deterministic HTTP/media fixtures so it
cannot replace a wallpaper or kill a process in the host session.

Real-desktop checks require a separate nested Wayland/Noctalia instance with
dedicated XDG config, data, cache, state, and runtime roots. A second profile in
the active desktop alone is not isolated because CLI IPC follows the active
instance environment. Carry the nested session's exact environment into every
test and recovery command, and begin mpvpaper checks with an empty disposable
`XDG_CONFIG_HOME` so ambient mpv scripts cannot alter the baseline.

An ordinary test run must not contact MotionBGS. Live-site testing is optional,
manual, serialized, and limited to a single search/detail request unless the
operator explicitly chooses a download.

### Current staging gate — 2026-08-02

- Repository validation, Noctalia plugin lint, both transport self-tests, Bash
  syntax checks, Nix parsing, and the complete expanded v0.5 offline contract
  pass on the current tree. The repository validator reports that `shellcheck`
  is not installed and therefore skips that optional lint.
- The complete five-service schema-4/runtime-6 VM passes for the current tree,
  including provider policy, internal renderer ownership, capture/pairing,
  mixed-playlist transitions, MotionBGS fixture download/deletion/re-download,
  persistence/reload recovery, exact panel compilation/rendering/IPC, delayed
  renderer-exit backoff, bounded palette teardown, and clean exact-PID cleanup.
  It also proves the wallpaper, theme mode, and color-scheme values are
  unchanged across disable. Real GPU, compositor, audio, and shell-theme
  effects remain manual desktop gates.
- The host has Noctalia 5.0.0, curl, FFmpeg/FFprobe,
  `linux-wallpaperengine`, Steam, `nc`, and SHA-256 support. It does not
  currently expose `mpvpaper`, so internal local/MotionBGS video playback is not
  a complete host-test path until that command is installed. A standalone
  `mpv` executable is not a separate Wall-in-One readiness requirement.

## Capability matrix

| Case | Expected result |
| --- | --- |
| No live renderer command | Noctalia still selection, manual static pairing, saved pairs, and direct MotionBGS link remain usable |
| Native Wallhaven enabled, no API key | Official-API SFW search/detail, local cached `thumbs.large` previews, and managed JPG/PNG download work; NSFW search is rejected locally |
| Native Wallhaven enabled, valid API key | The key is header-only and authenticated purity choices may be requested |
| Separate official Wallhaven plugin enabled | Its public browser remains an optional fallback; its downloads remain outside Wall-in-One ownership |
| External W Engine or mpvpaper plugin enabled, backend `auto` | External plugin owns playback; its public panel/controls remain available and internal apply is refused |
| Backend `internal`, external owner disabled | Wall-in-One starts only its own exact-PID child on the selected `bottom` or `background` layer and can apply a local video or numeric Workshop item |
| Both internal renderer commands installed | Different outputs may use different backends; switching one output stops its exact old child before starting the replacement |
| Matching provider force-disabled | Both its external routes and internal startup are disabled without disabling or signaling the provider itself |
| MotionBGS enabled, curl/helper ready | Bounded text search, latest/genre/4K page browsing, genre presets plus custom tags, still-thumbnail/poster preview, detail, and download commands are available |
| MotionBGS disabled or parser/preview degraded | Failed previews use placeholders and scraper actions fail visibly; **Open MotionBGS** still opens `https://motionbgs.com/` when `xdg-open` is available |
| Custom panel configured | The panel opens only while its owning plugin is enabled; no controls or status are inferred |

Before any playlist/schedule test, disable Noctalia's own wallpaper slideshow on
the test output. No public v5 plugin API pauses it, so leaving it enabled creates
a second independent wallpaper writer and invalidates transition assertions.
Disable foreign wallpaper plugins/applications on outputs used for internal
backend tests; `auto` deliberately yields to a detected external owner.

## Palette inventory and application contract

Test `palettes.luau` entirely against local fixtures except for one explicitly
chosen live catalog smoke. Assert the schema-1 command/status keys, monotonic
refresh nonce, built-ins/generators pinned from tag `v5.0.0-beta.7`, one
TTL-gated startup request, six-hour community cache, primary/backup recovery,
two-MiB response and cache cap, 512-entry inventory cap, and bounded
custom-directory scan. Invalid,
oversized, or malformed custom JSON must be excluded and reported without
discarding valid siblings.

Exercise the schema-1 `preview` action with a bounded nonce/key, one pinned
wallpaper scheme, and the pairing's selected or currently available absolute
still path. The exact worker command is
`noctalia theme <image> --scheme <scheme> --both -o <file>` and must only
generate preview JSON—it must not send theme-mode or color-scheme application
IPC. Assert `idle`/`loading`/`ready`/`error` status, bounded source metadata plus
SHA-256 identity, matching post-generation SHA-256, exact dark and light
surface plus four accent roles, the
512-KiB output cap, private temporary-file cleanup, stale-callback rejection,
one active plus only the latest pending request, and 16-entry in-memory cache
eviction. Repeating the same path/content/scheme must hit the cache; changing
content must regenerate even when size and whole-second mtime are preserved.
In **Auto**, the panel must show both dark and
light previews. An **Automatic still** pairing must remain preview-unavailable
until capture has created and validated its representative.

Exercise dark/light/auto and wallpaper/builtin/community/custom entry policies.
The transition order must be wallpaper success, theme-mode request, palette
request, then dynamic-renderer start. A missing community/custom selection must
remain requested in persisted config, visibly degrade to `builtin/Noctalia` at
runtime, and never be silently rewritten. Do not claim `color-scheme-get` proves
a community/custom file resolved or that `theme-mode-get` can distinguish the
configured `auto` token; test requested/configured/fallback reporting instead.

With two outputs due in the same update, assert that only the deterministic
palette winner writes the global theme. Test configured leader disconnect and
return, an empty leader setting, stale asynchronous completion rejection, and
serialized authority restoration after a non-authority switch. Other outputs
must still switch their wallpaper/renderer without writing the global palette.

## Wallhaven offline contract

Pin services `palettes`/`wallhaven` in the manifest and test Wallhaven with a
fake official API/CDN behind `scripts/bounded-fetch`. Assert schema-1 monotonic
`search`, `detail`, `download`, and `clear` commands; one active operation;
two-second API start spacing; 24 results; 512-KiB JSON; documented filter
validation; closed HTTPS route profiles; no redirects or ambient curl config;
private cancellation/credential cleanup; and exact Wallhaven API/CDN/thumbnail
origins. Public SFW search must omit `X-API-Key`; authenticated requests must
send one locally validated header through a private file, never process argv;
NSFW purity must fail before transport when the key is blank.

Search results use the API's validated `thumbs.large` value to populate the
attached hub's preview cache at `pluginDataDir()/provider-previews/v1`. Assert
that the panel gives `ui.image` only the resulting local path, never the remote
URL; the cache remains at most 64 entries and 64 MiB total; each response is at
most 2 MiB; and an invalid origin, redirect, oversized response, invalid image,
or transport failure retains the ordinary placeholder without hiding metadata
or actions.

Detail and download must accept only an ID in the current result set. Download
must reject a substituted URL/path, mismatched advertised size/type, non-JPG/PNG
signature, files over 64 MiB, and every pre-existing target/staging/sidecar.
Success must atomically leave both the managed image and `.wallhaven.json`
provenance; sidecar promotion failure must remove the promoted image. Confirm
that a separate official-plugin download has no delete action because it lacks
Wall-in-One provenance.

## MotionBGS offline contract

The transport helper self-test must accept same-origin relative URLs and safe
slugs, while rejecting cross-origin, scheme-relative, parent-traversal, and
invalid-slug inputs. Static tests must also pin:

- service ID `motionbgs`, entry `motionbgs.luau`, manifest-declared `bash` and
  `curl` external tools, plus fail-soft runtime detection;
- state keys `wall_in_one_motionbgs_command_v1`,
  `wall_in_one_motionbgs_command_ack_v1`,
  `wall_in_one_motionbgs_status_v1`, and
  `wall_in_one_motionbgs_results_v1`, all at schema 1;
- monotonically increasing nonces and `search`, `details`, `download`, and
  `clear` actions;
- query limit 80 bytes, result limit 1–48, queue limit eight, one-second
  request spacing, and cache limits of eight searches and 48 details;
- separate unpaged text search, pageable validated latest, genre/tag, and 4K routes,
  first-page-only HD browsing, public detail route `/<slug>`, and only numeric
  `/dl/hd|4k/<id>/` downloads;
- one-anchor-per-tick incremental listing parsing with one atomic result publication,
  keeping a full 36-card page below Noctalia's callback CPU budget;
- cache identity covering browse mode, selector, page, and limit; validated
  same-family previous/next links; and rejection of cross-catalog redirects;
- ambient curl configuration disabled, same-origin URL normalization, no
  challenge bypass, bounded errors, and a fail-closed `site-markup` state when
  cards or download anchors disappear;
- still-preview selection from the search thumbnail or detail poster, with no
  preview-video fetch, strict accepted image origins, no redirects, and only a
  local cached path passed to `ui.image`;
- one-MiB HTML cap, redirect cap three, configured 16–512 MiB MP4 cap,
  timeouts, content-type check, and MP4 `ftyp` signature validation; and
- same-directory temporary writes, atomic final installation, unique output
  names, and atomic `.motionbgs.json` provenance sidecars.

Search fixtures should contain at least two wallpaper-card anchors with a
`span.ttl`, same-origin image, and distinct slug. A genre/4K page fixture should
contain more than 24 cards plus validated previous/next links so the 48-card
ceiling and page metadata are exercised. Detail fixtures should include
both HD and 4K `/dl/<quality>/<numeric-id>/` anchors and JSON-LD duration. Add
negative fixtures for an explicit empty result, unrecognized markup, a browser
challenge, a cross-origin image/download, and a malformed ID. No fixture should
contain or execute third-party JavaScript.

For a download fixture, verify the final video and sidecar appear together and
that interruption, bad content type, an absent `ftyp`, a redirect off origin,
or a size overrun leaves neither a promoted video nor a lingering temporary
file. The sidecar must retain source page, resolved download URL, quality, byte
count, timestamp, and SHA-256 when available. It records provenance, not a
copyright license.

## Provider preview manual checks

1. Search each provider once and confirm result cards replace their placeholders
   with still images from local files beneath
   `pluginDataDir()/provider-previews/v1`.
2. Close and reopen the hub, repeat the same searches, and confirm cached images
   render without duplicate cache entries. Verify the cache stays within 64
   entries, 64 MiB total, and 2 MiB per file.
3. With the preview host blocked or a fixture returning a redirect, invalid
   image, or oversized body, confirm cards retain their placeholders while
   metadata, source/site links, and download actions remain usable.
4. For MotionBGS, confirm only its thumbnail/poster still is fetched, not a
   preview video, and that **Open MotionBGS** still opens
   `https://motionbgs.com/` as the independent backup path.

## Optional live MotionBGS smoke test

Use the hub rather than invoking undocumented endpoints directly:

1. Configure an existing writable video directory and keep the 48-result,
   256-MiB defaults.
2. Search once for a short ordinary term and confirm the UI states that the
   provider returns one unpaged text-search set. Then browse Latest, a preset
   and custom genre/tag, and a 4K page; use previous/next once, open one result, and confirm the
   service shows a cached still preview plus valid detail data, or a placeholder
   with a clear degraded/challenge state.
3. If downloading is appropriate, choose one HD item. Confirm the MP4 and JSON
   sidecar land in `Wall-in-One/MotionBGS` beneath the video root (or the
   explicit advanced override), then add the local file to a playlist.
4. Disable MotionBGS and verify the browser controls stop while the downloaded
   local file and direct-site link remain usable.

The bounded 2026-08-01 transport smoke completed search, detail, and one HD
download for `lost-space`. The 2,453,121-byte MP4 decoded with `ffprobe`, its
`ftyp` signature and SHA-256 matched the atomic provenance sidecar, and no
temporary files remained. This proves the live helper/download boundary; the
installed panel-to-service path is still part of the real desktop test.

Do not automate repeated live queries, weaken the one-second spacing, solve an
anti-bot challenge, log in, or treat a successful scrape as a stable API
guarantee. Stop the test if the site no longer permits this public access
pattern.

## Renderer ownership and lifecycle

The fake `mpvpaper` and `linux-wallpaperengine` commands must remain foreground
children so the supervisor can record their exact PIDs. Assert that:

- the default local-video start uses mpvpaper's current `--layer bottom`,
  `--auto-pause`, and one literal `-o` argument. It adds
  `--auto-mode <FULL|MAX|ACTIVE>` only when the installed command advertises
  that option; unsupported `ACTIVE` fails closed, and compositor auto-pause is
  treated as best effort;
- selecting `background` passes `--layer background` to subsequent mpvpaper and
  Wallpaper Engine starts when the installed Wallpaper Engine command
  advertises `--layer`; a legacy command permits only `bottom`, and any unknown
  layer fails closed;
- Wallpaper Engine uses the selected layer, the validated discovered project
  directory (or numeric Workshop-ID fallback), and only validated
  scaling/clamp/fps/volume flags;
- one output replacement terminates only Wall-in-One's previously owned child;
- stop, output removal, reload, disable, and service exit drain owned children
  and remove the instance FIFO;
- no path uses `pgrep`, `pkill`, a detached systemd scope, or a foreign PID
  file; and
- stale/replayed nonces, malformed fields, conflicting fullscreen-pause flags,
  and path/control-character injection are rejected.

In `auto` mode, seed enabled external-plugin fixtures and confirm neither fake
renderer launches. Change to `internal` only after removing the external owner,
then verify the expected child starts. Changing the mode or force-off setting
must reconcile and stop the matching owned child without touching unrelated
processes.

Install both renderer commands and start mpvpaper on one output and Wallpaper
Engine on another. Confirm both exact children remain active. Then switch one
output in both directions: the old exact PID must exit before the new child is
recorded, the other output must be unchanged, and no same-output overlap may
occur. Make the replacement fail and confirm the old child is not
automatically restarted. Repeat with the matching external provider enabled and
confirm internal startup fails closed instead of attempting an uncoordinated
handoff; separately document that a foreign provider of the other type is
outside Wall-in-One's system-wide exclusion guarantee.
Inspect the exact owned child's descendants during every transition and reject
any helper left behind after its parent stops. Exercise a renderer that survives
the initial startup check and then exits; status and private logs must be
captured before replacement/reload cleanup, and playlist recovery must be
backed off rather than forming a rapid advance/restart loop.

For internal mpvpaper, exercise pause/resume/toggle, mute/unmute/toggle-mute,
volume 0/100 and an intermediate value, stop, and stop-all through its private
socket. Wallpaper Engine must expose signal-based pause/resume/toggle and stop,
but reject mute/volume as unsupported. Send a burst up to the defensive queue
limit and verify ordering and overflow failure; ordinary user-paced actions
must keep queue depth near zero. Each command is written once. Missing or late
acknowledgements may report failure but must never cause automatic replay,
especially for apply and delete actions. Five-second supervisor heartbeats
must not publish unchanged renderer state, except when the heartbeat itself
acknowledges a pending FIFO write or reports recovery.

Exercise native Wallpaper Engine capture with no cached pair and through both
**Export** actions. The exact owned command must include the selected output,
numeric item identity in status, the validated project-directory source (or
numeric-ID fallback), selected layer, existing validated render options,
`--screenshot <pluginDataDir>/staging/capture-*.png`, and
`--screenshot-delay 1..5`. Keep the existing setting default 15 and range 1–120:
cooperative adapters receive the full configured value, while the internal
command receives that value clamped to linux-wallpaperengine's five-frame
maximum. Test the boundary values and the default. Assert that:

- capture sequentially replaces only the owned child for that output; a foreign
  renderer and unrelated sentinel retain their PIDs;
- the supervisor accepts only a non-empty stable artifact that the exact child
  has closed, times out after its bounded deadline, and emits `captured`,
  `capture-error`, or `cancelled` for the exact command nonce;
- the coordinator validates and atomically promotes the private PNG with capture
  method `linux-wallpaperengine-fbo-v1`, then removes staging state;
- capture of a previously running owned item restores it only while output,
  backend generation, provider policy, and Workshop ID are still current;
- applying or exporting a different Workshop while another owned renderer is
  active resolves the source/preview fallback without stopping that child, and
  replaces playback only after the still succeeds;
- failed native capture uses the source-video/preview fallback when still
  current, without claiming that fallback is a rendered frame; and
- concurrent requests are latest-waiting-wins, while stop, hotplug, mode change,
  reload, or disable cannot promote a stale pair or start delayed playback.

## Stills, pairing, and colors

Leave **Image wallpaper directory** empty and confirm it resolves to Noctalia's
configured wallpaper directory. An explicit root must be absolute, existing or
safely creatable by the helper, and must never cause a relative write. Manual
exports go directly in that root. With automatic capture enabled (the default),
generated video and Workshop representatives go into
`Wall-in-One/Automatic Stills` with adjacent ownership sidecars. While capture
runs, the temporary file stays beside its destination and is promoted only
after its image signature and optional full FFmpeg decode are valid.

Test local-video **Apply**, Workshop **Apply**, still-only Quick Choice, a
selected static representative, and a reused automatic source-to-still pair.
For every output confirm:

- the output-specific Noctalia wallpaper command succeeds before theme IPC and
  before the live renderer starts;
- a failed or cancelled capture never starts a delayed live renderer;
- the pair persists by output and dynamic source identity;
- the real still remains available to lock-screen fallback, overview/backdrop,
  hooks, and compositor blur/xray consumers; and
- only the authorized palette leader applies the entry's requested theme to
  Noctalia's one global palette.

With automatic capture enabled, remove any cached pair and confirm the entry
generates and validates a still before starting its renderer. Disable automatic
capture and repeat with no selected or cached pair: the apply must fail with the
still-required error, leave the renderer stopped, and not claim the current
Noctalia wallpaper as a pair. A valid cached automatic pair may still be reused
while the toggle is off, and disabling the policy must not delete it.

Set **Configured manual pair file** and invoke **Pair configured still**. The
validated image (or extracted PNG for a GIF) must be applied immediately as a
standalone backing. Then apply a different video/Workshop entry in **Automatic
still** mode and confirm the manual image is not silently copied into it. Bind
that image explicitly through **Selected still** in the entry editor when that
is the intended relationship.

Remove or make a configured local video unreadable. With a valid selected or
fingerprint-matched cached representative, activation must stop the live layer,
apply that still, and retain a visible degraded warning naming the missing
source. Without a valid representative it must block before changing the
backing. Separately use valid media and a valid still with the renderer command
unavailable and confirm the same visible degraded-live behavior.

After choosing a static, save a video and a Workshop entry with selected-still
mode. Their submitted/persisted bundles must contain that exact path, and later
applies must block if it disappears rather than silently substituting a generated
preview. Automatic-still mode may regenerate only its own missing managed pair.
For a selected animated GIF, confirm the durable pair is an extracted PNG in
the still directory rather than the animated source.

Create a new entry in the playlist editor and confirm its initial theme is the
explicit adaptive wallpaper policy (`auto` plus the first available wallpaper
generator, or `m3-tonal-spot`). Exercise **Keep Current** and all explicit theme
sources. Direct Quick Choice, library-add, and legacy/migration paths must use
`inherit` unless the compatibility color-sync setting deliberately selects the
configured wallpaper generator; no path may claim it captured an otherwise
unobservable current community/custom theme.

Create one reusable pairing in each still/video/Workshop drawer, insert the
same pairing into two playlists, and confirm each occurrence gets its own stable
entry ID while retaining the catalog `pairing_id`. Editing the catalog item must
update linked occurrence snapshots. Deleting the catalog card must unlink but
preserve already placed snapshots so neither playlist is corrupted.

An explicit Noctalia lock-screen image is user-managed and must remain
unchanged.

## Library roots and managed deletion

Choose separate image/video roots, then choose the same root for both. Confirm
supported entries remain separated by media type and a shared-root GIF appears
only under videos. Direct-root files are always labeled user-owned and never
show a delete action.

Confirm the image root receives marked `Wall-in-One/Wallhaven` and
`Wall-in-One/Automatic Stills` children. Native provider downloads in the first
receive valid `.wallhaven.json` sidecars and can be deleted only after the
coordinator revalidates that exact direct child. Downloads from the separate
official plugin remain user-owned. Automatic stills receive valid
`.wall-in-one.json` sidecars and are deletable.

When MotionBGS is enabled and its local helper requirements are ready, confirm
the default marked `Wall-in-One/MotionBGS` child appears beneath the video root.
Disabling the adapter before first use must not require that default directory;
an already existing cache is not silently removed when availability later
degrades. An explicit override remains the selected destination.

Delete a managed MotionBGS item through the two-step hub confirmation. The
service must re-resolve its opaque library ID, require the direct managed child
and matching sidecar, remove the video/sidecar, and remove only its managed
automatic pair. A manual/user-selected still must survive. Removing a file
outside Wall-in-One, changing a root, or unsubscribing from a Workshop item must
not trigger automatic deletion. Stale IDs, missing/tampered sidecars, nested
paths, path substitution, and user-root files must fail closed.

## Playlists, schedules, and persistence

Create, rename, duplicate, and delete named playlists. Assign one playlist to
two outputs and verify each output retains its own current entry, history,
shuffle bag, due time, and run state. Build a mixed playlist with a still, local
video, and Workshop ID; exercise rotate and shuffle-bag order, interval updates,
start, stop, pause, resume, next, previous, direct apply, ID-based reorder and
delete, and Quick Choice replacement. A one-entry playlist must apply once and
park without periodic wallpaper, palette, or renderer churn.

Add overlapping and overnight local-time schedule rules with explicit month
and weekday filters. Verify the weekday/month origin for an overnight span that
crosses a month boundary, displayed list reorder, and that the lowest active
rule in the persisted list wins. Also verify fallback playlist use, manual pin,
and **Resume schedule**. A clock/timezone/DST change must cause one reevaluation;
missed swaps must never replay in a burst. Stopping, pausing, removing an
in-flight entry, changing backend ownership, or removing an output must
invalidate pending capture/apply callbacks.

Gesture mappings, reusable pairing definitions, named playlists, entry
snapshots, output assignments, and list-ordered month/weekday schedules use
`config.json` schema 4. Provider observations, source pairs,
per-output/per-playlist execution, output schedule state, palette diagnostics,
and bounded active `current_workshops` use `runtime.json` schema 6. Seed config
schema 1–3 and runtime schema 1–5 and verify complete validation before a
recoverable coordinated migration with last-known-good backups. Schema-3
schedules with no month filter must migrate to all twelve months while retaining
their array order. Interrupt after each journal/rename stage and verify startup
either completes or rolls back both documents without installing a split schema
pair.

A corrupt or unknown future schema must fail closed without overwriting the
evidence. Also test an over-8-MiB document and current-schema documents with
oversized playlists, total entries, schedules, output maps, paths, run maps,
histories, or shuffle bags; each must remain disabled and visible in Diagnostics
without being republished. With `cycle_start_on_load` enabled, saved absolute
next-due timestamps resume without timer drift; with it disabled, runs load
disarmed. A running/paused exact owned W Engine child alone may populate its
output's numeric current-Workshop ID, and ownership loss must clear it.

## Manual desktop boundary

The VM can prove command construction and lifecycle ownership, but not whether
a real Wayland compositor displays the intended layer. On a disposable v5
session, manually check one output and then hotplug a second:

- apply a local video and a Workshop scene;
- verify the paired still remains Noctalia's wallpaper while each selected
  `bottom` and `background` live layer is visible;
- export a native Workshop screenshot on each layer, inspect the resulting PNG,
  and confirm a displaced owned item resumes without a second live child;
- check pause/resume/stop and output removal;
- reload and disable the plugin, ensuring no owned renderer remains while
  `wallpaper-get`, `theme-mode-get`, and `color-scheme-get` retain the last
  pairing's static backing and colors; and
- confirm a previously downloaded MotionBGS file behaves exactly like any
  other local video and does not require the network afterward.
