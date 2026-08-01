# Wall-in-One test record

Target: Noctalia `5.0.0-beta.7` / plugin API 17.

## Automated checks

- `noctalia plugins lint wall-in-one`
- `python3 wall-in-one/tests/test_contract.py`
- JSON parsing and translation-key coverage
- Luau formatting with StyLua when available
- The repository's headless NixOS VM checks

The local contract test pins the four entry types, native glyph setting,
provider panel/service IDs, public wallpaper and color APIs, cooperative W
Engine adapter boundary, still sources, absolute export-path rules, and storage
safety rules.

## Capability matrix

| Case | Expected result |
|---|---|
| No optional provider | Native selector/switching and validated manual pairing remain usable; configured-video export is available when optional ffmpeg is installed |
| Wallhaven enabled | Its public browser opens; no library state is read |
| W Engine enabled, no adapter | Panel and documented controls work; configured Workshop ID exports a video frame or preview |
| W Engine status adapter | Current ID is shown for its output; automatic fallback export may be enabled |
| W Engine capture adapter | With optional ffmpeg, the adapter writes and returns exactly Wall-in-One's unique requested staging PNG; without it, export uses the Workshop source/preview fallback |
| mpvpaper enabled with commands | Picker and documented pause/resume/toggle/clear controls work |
| mpvpaper commands missing | Picker remains discoverable; capability text warns that playback cannot start |
| Custom panel configured | Panel opens only while its owning plugin is enabled; no controls are inferred |

No-adapter W Engine tests must confirm that Wall-in-One does not claim an
active-frame capture, scrape process arguments, launch another renderer, or
signal the provider-owned process.

After every successful enabled-plugin discovery with W Engine present, assert
that the coordinator sends exactly one `wall-in-one-probe-v1` service event. A
v1 adapter must answer by re-sending `provider-capabilities-v1` and the current
`provider-current-v1` records. Confirm a fresh response retains adapter status,
capture capability, and per-output IDs. Withhold the response and advance 10
seconds: those stale adapter flags and current IDs must clear, while W Engine's
panel/public controls remain available and export returns to configured
Workshop source/preview fallback.

## Export paths and helper safety

With **Still directory** empty, verify every stable export is created under
`pluginDataDir()/captures`. Configure another absolute directory and verify
exports move there. A relative configured path must be rejected with one
bounded error; it must not create a directory relative to the service's working
directory.

For each helper mode, inspect the destination directory while the command is
running. Its temporary output must be in that same directory, use a non-image
`.part` name, and become the stable destination only after validation. Interrupt
the helper and confirm neither a partial stable image nor a lingering `.part`
file remains.

Run the static copy/validation and manual-pair cases without `ffmpeg`: they must
still work using image-signature validation. Only configured-video, Workshop
video, and animated-image frame extraction should become unavailable. A
cooperative rendered-capture request must safely use its Workshop
source/preview fallback because the returned PNG cannot receive full decode
validation. Installing `ffmpeg` should restore those paths and add full decode
validation to static images without changing provider or pairing behavior.

With optional `ffmpeg` present, assert that each cooperative W Engine request
uses a fresh PNG under `pluginDataDir()/staging`. Return an existing image at
another path and confirm it is rejected, then write the requested file and
return that **exact** path. Test delays 1 and 120, reject a setting above 120,
and verify the request deadline is `max(60 seconds, delay + 60 seconds)` rather
than the helper's ordinary extraction timeout.

## Pairing and colors

Test configured-video **Export + pair**, W Engine fallback **Export + pair**,
adapter-owned rendered capture, and **Pair selected still** independently.
For manual pairing, confirm the helper validates the source before
`setWallpaper` is called and that an invalid or truncated image leaves the
previous pair unchanged. A valid source must remain in place and must not be
copied into the export directory.

For each target output verify that:

- the selected/exported image becomes Noctalia's persisted wallpaper;
- the live provider remains running and owned by its plugin;
- the path is recorded in `runtime.json` with its capture method;
- overview/backdrop and wallpaper consumers receive a real static image;
- color source/scheme changes only when color sync is enabled, except for
  Noctalia's natural regeneration when the existing source is already
  `wallpaper`;
- the configured palette leader wins after pairing another output; and
- an explicit lock-screen override is reported as a user-managed exception,
  not silently changed.

## Persistence and lifecycle

Gesture changes write schema-v1 `config.json`; provider/pair observations write
schema-v2 `runtime.json`. Seed a valid legacy schema-v1 `runtime.json`, reload,
and confirm it is migrated once to schema 2 through temporary-file replacement
while the prior valid document is retained as the `.bak` last-known-good copy.
Reload the migrated state again and confirm the migration is idempotent. Corrupt
either file or use an unknown future schema and confirm routing fails closed
without replacing the evidence.

Reload, disable, and uninstall Wall-in-One while W Engine and mpvpaper are
active. Their renderer PIDs and current sources must remain untouched. Removing
Wall-in-One must leave paired wallpaper files and Noctalia's persisted wallpaper
choice intact.

Timed mixed static/live reels remain out of scope for `0.2.0`; no Wall-in-One
scheduler should appear during these tests.
