# Wall-in-One provider adapters

Wall-in-One `0.4.0` separates three integration boundaries: Noctalia's native
wallpaper APIs, public interfaces exposed by other Noctalia plugins, and
processes owned directly by Wall-in-One. External plugins are discovered with
`noctalia msg plugins list` and are contacted only through public panels or
documented service events. Noctalia v5 does not expose another plugin's private
state, so enabled and ready are deliberately separate states.

## Built-in provider registry

| Provider | Public integration |
| --- | --- |
| Noctalia | Wallpaper panel and `wallpaper-next`, `wallpaper-previous`, and `wallpaper-random` |
| Wallhaven | `noctalia/wallhaven:browser` panel |
| W Engine | Panel plus `next`, `cycle-stop`, and `stop` on `tadomika_ari/w-engine:start` |
| mpvpaper | Picker plus `pause`, `resume`, `toggle`, `clear`, and `clear-all` on `noctalia/mpvpaper:service` |
| MotionBGS | Wall-in-One's bounded public-page search/download service plus an independent direct-site link |
| Custom | A user-configured full `author/plugin:panel` ID, open-only |

The current external W Engine and mpvpaper releases do not publicly report the
active source or return data from their service IPC. Wall-in-One therefore
never reads their private state, PID files, process arguments, or caches.
`auto` backend mode prefers one of those enabled external owners. `external`
mode requires it. `internal` mode is available only after the matching external
plugin is disabled; it lets Wall-in-One start its own `mpvpaper` or
`linux-wallpaperengine` child and apply a source directly. An independently
disabled provider toggle overrides all three modes without disabling the other
plugin or killing a foreign process.

The internal Wallpaper Engine library scans Steam's ordinary
`steamapps/workshop/content/431960` directories and an optional user-selected
directory. That is the user's installed Workshop cache, not a Noctalia
plugin-private cache. Relative paths read from `project.json` remain contained
inside the numeric item directory.

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

## MotionBGS public-page adapter v1

MotionBGS does not publish a stable, versioned API. The `motionbgs` service is
therefore an unofficial, best-effort public-page adapter, not an assertion of
partnership or API compatibility. It recognizes only these same-origin routes:

- `/search?q=<query>` for a bounded result page;
- `/<slug>` for one wallpaper detail page; and
- `/dl/hd/<numeric-id>/` or `/dl/4k/<numeric-id>/` for the selected MP4.

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

- one serialized request queue, one-second spacing, and at most eight queued
  operations;
- at most 24 results, 80 query bytes, eight cached searches, and 48 cached
  detail records;
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
`pluginDataDir()/staging` directory and is unique to the request. The frame
delay is clamped to 1–120 frames. W Engine must capture through its existing
per-output renderer or perform one controlled owner-managed restart. It must
never run a concurrent second renderer. Write through a provider-owned
temporary file, validate the PNG, atomically install it at the exact requested
staging path, then call back Wall-in-One:

```text
event: capture-result-v1
success payload: <request-id><TAB>ok<TAB><exact-staging-path>
failure payload: <request-id><TAB>error<TAB><bounded-detail>
```

Wall-in-One rejects mismatched paths, control characters, stale request IDs,
and missing results. It validates the returned image through its export helper,
copies it into the selected capture directory, removes the private staging
file, and optionally persists the validated result with
`noctalia.setWallpaper(connector, path)`. The deadline is the greater of 60
seconds or the configured frame delay plus 60 seconds. Failure and timeout
cleanup both drain any queued work for that output. Automatic capture is off by
default and only reacts to adapter-reported status.

Rendered adapter capture requires the optional `ffmpeg` command for full PNG
decode validation. Without it, Wall-in-One does not weaken the exact-path
contract; it falls back to the Workshop source/preview path. Static preview
copies and manual static pairing still use signature validation without
`ffmpeg`.

Without this handshake, a configured Workshop ID still supports safe fallback:
Wallpaper Engine video projects use FFmpeg to export a real frame; scene and web
projects copy or decode their Workshop preview. This is a representative static
pair, not a claim that the current rendered framebuffer was captured.
