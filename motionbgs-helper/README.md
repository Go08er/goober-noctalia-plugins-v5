# Wall-in-One MotionBGS helper

`wall-in-one-motionbgs` is the separately installed MotionBGS process adapter
for the Wall-in-One Noctalia plugin. It fetches and parses MotionBGS public
pages outside Noctalia's time-bounded Luau callbacks. The plugin remains fully
usable without it; only the integrated MotionBGS shop is unavailable.

The helper is deliberately conservative. It uses ordinary unauthenticated
HTTPS requests, does not execute page scripts, does not retain cookies, and
does not attempt to solve or bypass an anti-bot challenge. A changed page or
access policy fails closed and leaves the direct `https://motionbgs.com/` link
available.

## Requirements and installation

- Python 3.11+;
- `curl`; and
- Linux or another Unix system with `flock` and file-size resource limits.

Install the executable somewhere controlled by your user, or run it directly
from this checkout. For example:

```sh
install -Dm0755 motionbgs-helper/wall-in-one-motionbgs \
  "$HOME/.local/bin/wall-in-one-motionbgs"
```

Set Wall-in-One's **MotionBGS binary path** to that absolute path. Leaving the
setting blank allows the plugin to look for the fixed
`wall-in-one-motionbgs` command on `PATH`. Wall-in-One never downloads or
installs this program automatically.

Check the local, network-free probes before configuring the plugin:

```sh
wall-in-one-motionbgs self-test
wall-in-one-motionbgs probe --protocol 1
```

The probe result is exactly:

```text
WIO-MBGS-PROBE1	ok	1	1.0.0	search,details,download,clear
```

## Process interface

The plugin invokes the helper through its bundled bounded launcher:

```text
motionbgs-provider probe BINARY
motionbgs-provider rpc BINARY ABS_REQUEST ABS_RESPONSE ABS_GUARD
```

The launcher in turn uses this program's stable interface:

```text
wall-in-one-motionbgs probe --protocol 1
wall-in-one-motionbgs rpc --protocol 1 --request ABS_REQUEST --response ABS_RESPONSE --guard ABS_GUARD
wall-in-one-motionbgs self-test
```

An RPC request is a UTF-8 schema-1 JSON object of at most 8 KiB. The request
file and the unique response path must be inside the current user's existing
cache directory. All requests contain:

```json
{
  "schema": 1,
  "request_id": "123-1",
  "action": "search",
  "cache_directory": "/absolute/private/cache",
  "cache_ttl_seconds": 1800,
  "guard_path": "/absolute/private/cache/.wall-in-one-motionbgs-guard-RUNTIME-NONCE-SEQUENCE",
  "operation_timeout_ms": 30000
}
```

The bridge creates the guard immediately before launching the RPC. It must be
a current-user-owned, non-symlink regular file inside `cache_directory`, named
`.wall-in-one-motionbgs-guard-RUNTIME-NONCE-SEQUENCE`, containing exactly the
16 bytes `WIO-MBGS-GUARD1\n`. Removing it revokes the operation on
configuration change, reload, exit, or timeout. The helper checks the guard
before each network hop and at safe parse/cache checkpoints, and checks it
immediately before a no-replace media install. Non-download operations receive
a 30-second end-to-end helper budget. Downloads receive 75 seconds inside the
helper and an 80-second host timeout, enough for one uncached 20-second detail
request, bounded request spacing, and the configured 50-second media transfer
without letting work run unbounded.

Action-specific fields are:

| Action | Required fields |
| --- | --- |
| `search` | `mode`, normalized `query`, `genre`, `page`, `limit`; optional boolean `force` |
| `details` | `slug`; optional boolean `force` |
| `download` | `slug`, `quality`, `download_directory`, `managed_marker_path`, `max_download_bytes`, `download_timeout_seconds`; optional boolean `force` |
| `clear` | no additional fields; the common TTL is informational |

Browse modes are `search`, `latest`, `genre`, `4k`, and first-page-only `hd`.
Queries are 1–80 UTF-8 bytes, result limits are 1–48, cache TTLs are 5
minutes–24 hours, and downloads are capped at 16–512 MiB. The inter-request
delay is fixed at one second and cannot be weakened by a request.

The program installs one response JSON object without replacing an existing
path. It is at most 128 KiB, and completion is reported on stdout as:

```text
WIO-MBGS-RPC1	ok	REQUEST_ID	ABS_RESPONSE	BYTES
```

Invalid invocation or local transport failures instead return one bounded
line:

```text
WIO-MBGS-RPC1	error	KIND	DETAIL
```

Expected provider failures—such as a challenge, changed markup, or an HTTP
error—still produce an authenticated-to-the-request response object with
`"ok": false` and a bounded `error.kind`/`error.message`. That lets the plugin
match the failure to its nonce without treating provider behavior as a broken
process protocol.

Successful response bodies preserve the plugin's existing provider model:

- search: `cached`, `source_url`, `fetched_at`, browse fields, `items`, and
  pagination `meta`;
- details: `cached`, `source_url`, `fetched_at`, and `selected`;
- download: `cached`, `source_url`, `fetched_at`, the full normalized
  `selected` detail, and a `download` object containing the installed path,
  adjacent sidecar, provenance, byte count, MIME type, and SHA-256; and
- clear: `cleared: true`.

Every response also includes `schema`, `ok`, `action`, and the exact
`request_id`.

## Security and storage boundaries

- URLs are constructed from semantic request fields. Callers cannot supply an
  origin or arbitrary provider URL.
- Only exact `https://motionbgs.com` URLs are accepted. Automatic curl
  redirects are disabled; each bounded same-origin redirect is validated and
  fetched as a new request, with effective-URL equality required every time.
- A successful download must finish on the requested numeric HD/4K route or a
  same-ID `/media/<id>/*.mp4` route. A redirect to another wallpaper ID is
  rejected before validation or installation.
- HTML is capped at 1 MiB and must match an HTML MIME type and signature.
  Parsed tags, attributes, text, result counts, and output fields are bounded.
- MP4 downloads are streamed under both curl's limit and `RLIMIT_FSIZE`. The
  response MIME type must agree with an ISO-BMFF `ftyp` signature.
- The metadata cache is capped at 2 MiB, eight searches, and 48 details. A
  private lock serializes cache changes and network request starts.
- Download directories must already exist and contain Wall-in-One's exact
  managed-directory marker. Media and `.motionbgs.json` provenance are
  installed from mode-0600 temporary files with no-replace links. A partial
  pair is rolled back.
- Request, response, cache, marker, and download paths reject controls,
  traversal components, symlinks at trust boundaries, foreign ownership, and
  unexpected replacement.
- The request's cancellation guard is path-bound in both the JSON envelope and
  command line. Its removal prevents a stale operation from publishing a
  response or installing media after Wall-in-One has invalidated it.

Downloaded artwork remains subject to its provider's terms. The provenance
sidecar records origin and Wall-in-One deletion authority; it does not grant
redistribution rights.
