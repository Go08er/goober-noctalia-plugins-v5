# Wall-in-One backend

`wall-in-one-backend` is the separately installed, one-shot Python process
backend for the Wall-in-One Noctalia plugin. It keeps bounded bulk work outside
Noctalia's CPU-budgeted Luau callbacks. Version 0.8 delegates local-library
scanning, external palette inventory, provider-thumbnail cache maintenance,
Wallhaven search/detail/download work, and the MotionBGS provider integration.
It is deliberately one executable with bounded subcommands, not a collection
of independently installed helpers.

The plugin remains partially usable without this program. A missing or
incompatible backend prevents a fresh local-library index, external palette
inventory refresh, provider preview refresh, and integrated Wallhaven and
MotionBGS shop operations. Previously configured playlists, Noctalia wallpaper
and palette application, adaptive palette preview generation, renderer
controls, and direct provider links remain host-owned and available.

## Requirements

- Python 3.11 or newer;
- Linux or another Unix system with `fcntl` locks and file-size resource limits;
- `curl` for bounded Wallhaven, palette-catalog, thumbnail, and MotionBGS
  network operations; and
- `sha256sum` for the documented installation check.

## Installation

Wall-in-One never downloads, updates, or executes newly downloaded code on the
user's behalf. Install the program somewhere controlled by your user, ensure it
is executable, then either put the fixed `wall-in-one-backend` name on the
environment inherited by Noctalia or select its absolute path under
**Wall-in-One backend program**.

For a repository checkout you already trust:

```bash
cd /path/to/goober-noctalia-plugins-v5
(cd wall-in-one-backend && sha256sum -c wall-in-one-backend.sha256)
install -Dm755 wall-in-one-backend/wall-in-one-backend \
  "$HOME/.local/bin/wall-in-one-backend"
wall-in-one-backend self-test
wall-in-one-backend probe --protocol 1
```

Once a Wall-in-One 0.8 release publishes both named assets, download them as
inert data, verify the digest, and only then grant execute permission. These
commands are not a claim that the 0.8 release assets already exist:

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
checksum. Because both files are hosted with the same release, independently
verify the release tag/account through a trusted GitHub view when provenance
matters. Do not use an unpinned `curl | sh` pipeline.

## Generic process interface

The plugin's thin Luau bridges invoke the program through the bundled
`wall-in-one/scripts/backend-provider` launcher. Local, network-free checks are:

```text
wall-in-one-backend self-test
wall-in-one-backend probe --protocol 1
```

The probe returns one tab-separated record:

```text
WIO-BACKEND-PROBE1	ok	1	0.1.0	library.scan,palettes.inventory,preview.sync,wallhaven.search,wallhaven.detail,wallhaven.download,wallhaven.clear
```

One RPC invocation is:

```text
wall-in-one-backend rpc --protocol 1 --request ABS_REQUEST --response ABS_RESPONSE --guard ABS_GUARD
```

The schema-1 request is bounded to 64 KiB. Every action uses an exact field set,
private direct-child request/response files, one same-directory cancellation
guard, and an action-specific bounded deadline. The caller cannot request an
arbitrary operation: generic interface 1 accepts only `library.scan`,
`palettes.inventory`, `preview.sync`, `wallhaven.search`,
`wallhaven.detail`, `wallhaven.download`, and `wallhaven.clear`.

`library.scan` is non-recursive. It validates managed sidecars and Workshop
`project.json`, derives ownership/deletion metadata, restores validated dynamic
representatives from runtime state, sorts the inventories, and caps candidates
and results. The backend writes 12-item image/video/Workshop page files plus one
bounded manifest. Each file is installed without replacement under the private
`pluginDataDir()/backend-bridge-v1/rpc` transport. The Luau bridge validates a
fixed number of records per update before publishing one complete inventory.

A successful process emits exactly:

```text
WIO-BACKEND-RPC1	ok	REQUEST_ID	ABS_RESPONSE	BYTES
```

Protocol or transport errors use one bounded `WIO-BACKEND-RPC1` error record.
Operation errors are encoded in the response object so the bridge can match
them to the request nonce.

`palettes.inventory` scans bounded custom-palette files and maintains the
six-hour community catalog plus last-known-good backup at
`pluginDataDir()/palettes-cache.json` and `.bak`. It returns normalized
inventory pages; it does not apply a theme. Adaptive per-image previews still
use Noctalia's non-applying `noctalia theme` command and source hashing in the
Luau palette service.

`preview.sync` owns the bounded LRU manifest and local image files beneath
`pluginDataDir()/provider-previews/v1`. It accepts only normalized Wallhaven or
MotionBGS thumbnail identities and invokes the bundled strict thumbnail
launcher; Luau receives validated local filenames, never remote image bytes.

The four `wallhaven.*` actions own API/CDN transport, response normalization,
request spacing, media validation, and atomic no-replace installation. Their
private one-shot RPC files live under
`pluginDataDir()/wallhaven-bridge-v2/rpc`; an optional API key is passed in a
mode-0600 direct-child file and used only as the `X-API-Key` header.

## MotionBGS compatibility interface

MotionBGS has no stable public API. Its HTTP, HTML parsing, metadata cache, and
managed download work remain process-isolated in this same executable. The
existing Luau bridge uses compatibility commands so the provider's schema-1
state contract does not change:

```text
wall-in-one-backend motionbgs-probe --protocol 1
wall-in-one-backend motionbgs-rpc --protocol 1 --request ABS_REQUEST --response ABS_RESPONSE --guard ABS_GUARD
wall-in-one-backend motionbgs-self-test
```

The probe advertises `search,details,download,clear` on `WIO-MBGS-PROBE1`.
Requests are at most 8 KiB; responses are at most 128 KiB. Browse modes are
text search, latest, genre/tag, 4K, and first-page-only HD. Queries are 1–80
UTF-8 bytes, result limits are 1–48, cache TTLs are 5 minutes–24 hours, and
downloads are capped at 16–512 MiB.

Every operation is a fresh process. The bridge uses revocable guards and
end-to-end deadlines; removing the guard cancels work before another network
hop, cache publication, response publication, or media install. The interface
reports queued, active, and complete phases, not invented byte-level progress.

## Security and storage boundaries

- Generic requests accept only fixed schema fields and the seven advertised
  capabilities. Roots, transport/cache paths, runtime files, page names, item
  counts, metadata sizes, and deadlines are bounded per action.
- Writable request, response, cache, marker, and download paths reject control
  characters, traversal components, symlinks at trust boundaries, foreign
  ownership, and unexpected replacement. Custom palette inventory is the
  deliberate read-only exception: its directory and JSON entries may resolve
  through declarative-config symlinks, including root-owned `/nix/store`
  targets. Entries are opened relative to one stable directory descriptor;
  descriptor identity and size are checked with `fstat` before and after the
  bounded read, and bytes are read only from that descriptor. Wall-in-One never
  writes or deletes through those paths.
- Same-directory temporary files plus no-replace installation prevent partial
  or stale results from replacing a current response. A private `flock`
  serializes scans; cancellation guards and deadlines remain live while waiting.
- Wallhaven API/CDN, community-palette, and provider-thumbnail requests use
  fixed HTTPS origins, disabled ambient curl configuration, no automatic
  redirects, effective-URL equality, bounded bodies, and content validation.
- MotionBGS URLs are constructed from semantic request fields and restricted to
  exact `https://motionbgs.com` origins. Automatic redirects are disabled; each
  bounded same-origin redirect is validated and its effective URL must match.
- MotionBGS HTML is capped at 1 MiB and parser tags/attributes/results are
  bounded. MP4 payloads have curl and `RLIMIT_FSIZE` ceilings. Declared MIME is
  cross-checked against signatures.
- Managed MP4 and provenance sidecars are installed atomically without
  replacing existing files. The program does not log in, retain cookies,
  execute page scripts, bypass challenges, or crawl in bulk.

Downloaded artwork remains subject to its provider's terms. A provenance
sidecar records origin and Wall-in-One deletion authority; it does not grant
redistribution rights.

## Development checks

```bash
./wall-in-one-backend/wall-in-one-backend self-test
python3 -m unittest discover -s wall-in-one-backend/tests -p 'test_*.py' -v
bash wall-in-one/scripts/backend-provider self-test
bash wall-in-one/scripts/motionbgs-provider self-test
```
