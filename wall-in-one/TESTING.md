# Wall-in-One test record

Target: Wall-in-One `0.4.0`, Noctalia `5.0.0-beta.7`, plugin API 17.

## Automated checks

Run from the repository root:

```bash
python3 tools/validate.py
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
bash wall-in-one/scripts/motionbgs-provider self-test
nix build -L .#vm-test-wall-in-one
```

The repository validator and contract test cover the manifest, all three
services, panel/widget/shortcut entry points, translation keys, helper
permissions, static pairing, scheduler persistence, internal-renderer protocol,
and MotionBGS's bounded offline contract. The NixOS VM supplies fake renderer
commands and deterministic files so it cannot replace a wallpaper or kill a
process in the host session.

An ordinary test run must not contact MotionBGS. Live-site testing is optional,
manual, serialized, and limited to a single search/detail request unless the
operator explicitly chooses a download.

## Capability matrix

| Case | Expected result |
| --- | --- |
| No live renderer command | Noctalia still selection, manual static pairing, saved pairs, and direct MotionBGS link remain usable |
| Official Wallhaven plugin enabled | Its public browser opens; Wall-in-One does not duplicate its API-key/search/download implementation |
| External W Engine or mpvpaper plugin enabled, backend `auto` | External plugin owns playback; its public panel/controls remain available and internal apply is refused |
| Backend `internal`, external owner disabled | Wall-in-One starts only its own exact-PID child on the bottom layer and can apply a local video or numeric Workshop item |
| Matching provider force-disabled | Both its external routes and internal startup are disabled without disabling or signaling the provider itself |
| MotionBGS enabled, curl/helper ready | Bounded search, detail, and download commands are available |
| MotionBGS disabled or parser degraded | Scraper actions fail visibly; **Open MotionBGS** still opens `https://motionbgs.com/` when `xdg-open` is available |
| Custom panel configured | The panel opens only while its owning plugin is enabled; no controls or status are inferred |

## MotionBGS offline contract

The transport helper self-test must accept same-origin relative URLs and safe
slugs, while rejecting cross-origin, scheme-relative, parent-traversal, and
invalid-slug inputs. Static tests must also pin:

- service ID `motionbgs`, entry `motionbgs.luau`, hard `bash` dependency, and
  optional runtime detection of `curl`;
- state keys `wall_in_one_motionbgs_command_v1`,
  `wall_in_one_motionbgs_command_ack_v1`,
  `wall_in_one_motionbgs_status_v1`, and
  `wall_in_one_motionbgs_results_v1`, all at schema 1;
- monotonically increasing nonces and `search`, `details`, `download`, and
  `clear` actions;
- query limit 80 bytes, result limit 1–24, queue limit eight, one-second
  request spacing, and cache limits of eight searches and 48 details;
- public routes `/search?q=...`, `/<slug>`, and only numeric
  `/dl/hd|4k/<id>/` downloads;
- same-origin URL normalization, no challenge bypass, bounded errors, and a
  fail-closed `site-markup` state when cards or download anchors disappear;
- one-MiB HTML cap, redirect cap three, configured 16–512 MiB MP4 cap,
  timeouts, content-type check, and MP4 `ftyp` signature validation; and
- same-directory temporary writes, atomic final installation, unique output
  names, and atomic `.motionbgs.json` provenance sidecars.

Search fixtures should contain at least two wallpaper-card anchors with a
`span.ttl`, same-origin image, and distinct slug. Detail fixtures should include
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

## Optional live MotionBGS smoke test

Use the hub rather than invoking undocumented endpoints directly:

1. Configure an existing writable video directory and keep the 24-result,
   256-MiB defaults.
2. Search once for a short ordinary term, open one result, and confirm the
   service shows either valid detail data or a clear degraded/challenge state.
3. If downloading is appropriate, choose one HD item. Confirm the MP4 and JSON
   sidecar land in the selected directory, then add the local file to a cycle.
4. Disable MotionBGS and verify the search controls stop while the downloaded
   local file and direct-site link remain usable.

Do not automate repeated live queries, weaken the one-second spacing, solve an
anti-bot challenge, log in, or treat a successful scrape as a stable API
guarantee. Stop the test if the site no longer permits this public access
pattern.

## Renderer ownership and lifecycle

The fake `mpvpaper` and `linux-wallpaperengine` commands must remain foreground
children so the supervisor can record their exact PIDs. Assert that:

- local video uses mpvpaper's current `--layer bottom`, `--auto-pause FULL|MAX`,
  `--auto-mode`, and one literal `-o` argument;
- Wallpaper Engine uses `--layer bottom`, numeric Workshop IDs, and only
  validated scaling/clamp/fps/volume flags;
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

## Stills, pairing, and colors

Leave **Still directory** empty and confirm generated frames go to Noctalia's
configured wallpaper directory. An explicit directory must be absolute,
existing or safely creatable by the helper, and must never cause a relative
write. While capture runs, the temporary file stays beside its destination and
is promoted only after its image signature and optional full FFmpeg decode are
valid.

Test local-video **Apply + pair**, Workshop **Apply + pair**, manual static
pairing, and a reused source-to-still pair. For every output confirm:

- `setWallpaper` succeeds before the live renderer starts;
- a failed or cancelled capture never starts a delayed live renderer;
- the pair persists by output and dynamic source identity;
- the real still remains available to lock-screen fallback, overview/backdrop,
  hooks, and compositor blur/xray consumers; and
- color source/scheme changes only when color sync is enabled, with the chosen
  palette leader winning Noctalia's one global palette.

After pairing a chosen static, apply and enqueue a video and a Workshop item.
Their submitted/persisted entries must contain that `still_path`, and later
applies must reuse it instead of silently substituting a generated preview.
For a selected animated GIF, confirm the durable pair is an extracted PNG in
the still directory rather than the animated source.

An explicit Noctalia lock-screen image is user-managed and must remain
unchanged.

## Mixed scheduler and persistence

Build one cycle with a static path, local video, and Workshop ID. Exercise
sequential, shuffle-bag, and random order; interval updates; start, stop, pause,
resume, next, previous, random, entry removal, and clear. Stopping, pausing,
clearing, removing an in-flight entry, changing backend ownership, or removing
an output must invalidate any pending capture callback so it cannot launch a
renderer later.

Gesture mappings and per-output reel entries use `config.json` schema 2.
Provider observations, source pairs, and cycle execution use `runtime.json`
schema 3. Seed supported schema-1/2 state and verify one atomic migration plus
last-known-good backup. A corrupt or unknown future schema must fail closed
without overwriting the evidence. Also test an over-8-MiB document and a
current-schema document with oversized registries, output maps, paths,
histories, or sparse bags; each must remain disabled and visible in Diagnostics
without being republished. With `cycle_start_on_load` enabled, saved
absolute next-due timestamps should resume without accumulating timer drift.
With it disabled (the default), a reload must persist every cycle as disarmed
(`running=false`, `paused=false`, `next_due=0`).

## Manual desktop boundary

The VM can prove command construction and lifecycle ownership, but not whether
a real Wayland compositor displays the intended layer. On a disposable v5
session, manually check one output and then hotplug a second:

- apply a local video and a Workshop scene;
- verify the paired still remains Noctalia's wallpaper while the dynamic bottom
  layer is visible;
- check pause/resume/stop and output removal;
- reload and disable the plugin, ensuring no owned renderer remains; and
- confirm a previously downloaded MotionBGS file behaves exactly like any
  other local video and does not require the network afterward.
