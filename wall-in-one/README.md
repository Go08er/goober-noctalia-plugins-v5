# Wall-in-One

Wall-in-One is a Noctalia v5 wallpaper coordinator. It gives static and live
wallpaper providers one bar widget and one attached hub while leaving every
renderer and library under its original plugin's control.

Version `0.2.0` can persist a real static image underneath a live wallpaper.
That paired image gives Noctalia, the lock screen, overview/backdrop, wallpaper
hooks, and compositor blur or xray integrations an actual wallpaper path even
when Wallpaper Engine or mpvpaper is only an application on the background
layer.

## Providers and controls

Wall-in-One discovers enabled plugins with Noctalia's public
`plugins list` command. It currently understands:

- **Noctalia wallpapers:** open the native selector and request next, previous,
  or random static wallpapers.
- **Wallhaven:** open the official `noctalia/wallhaven:browser` panel. Wallhaven
  retains download and library ownership.
- **W Engine:** open `tadomika_ari/w-engine:w-engine-panel` and call its public
  `next`, `cycle-stop`, and `stop` service events.
- **mpvpaper:** open the official `noctalia/mpvpaper:picker` and call its public
  pause, resume, toggle, per-output clear, and clear-all events.
- **One custom provider panel:** discover and open a configured full
  `vendor/plugin:panel` ID. This adapter is intentionally open-only because
  Noctalia v5 has no generic cross-plugin capability API.

Provider controls use documented Noctalia plugin IPC. Wall-in-One does not read
another plugin's `data.json`, infer private playback state, or launch/kill a
provider-owned renderer.

The default widget gestures remain native selector / Wallhaven / W Engine for
left / middle / right click. Every gesture can instead run any available
provider, still-export, pairing, or hub action. Saved actions remain visible as
**configured but unavailable** if a provider disappears; there is no silent
fallback. The widget retains Noctalia's native searchable glyph selector,
per-placement label, visibility, and theme-token color controls.

## Still export

Leave **Still directory** empty to keep exports in
`pluginDataDir()/captures`, Wall-in-One's private data directory. A directory
selected in settings is an explicit export location and must be an absolute
path; relative paths are rejected rather than interpreted against an
unspecified working directory.

Three explicit paths are supported:

1. **Configured video:** select a video/animated-image file and frame time.
   Wall-in-One uses the optional `ffmpeg` command to export a real frame. This
   path is deterministic and does not depend on another plugin.
2. **Wallpaper Engine Workshop item:** use the active numeric item reported by
   a cooperative W Engine status adapter, or configure a numeric **Workshop ID
   fallback**. Video projects export a real source-video frame. Scene/web
   projects copy their Workshop preview unless the adapter advertises rendered
   capture.
3. **Manual static backing:** select an existing image. Wall-in-One validates
   it through the same bounded helper used for exports before pairing the
   original path. Validation uses and removes a temporary staging copy; no
   lasting export copy is retained, so choose a durable source path.

When `ffmpeg` is absent, only decode-dependent capture degrades: video or
animated-image frame extraction is unavailable, and a cooperative adapter's
rendered PNG cannot receive full decode validation, so that request safely uses
the Workshop source/preview fallback. Provider discovery and controls, static
Workshop preview copies, image-signature validation, manual pairing, and
pairing an already exported static image remain available. Accordingly, the
manifest requires only `bash`; `ffmpeg` is an optional runtime enhancement.

The export helper creates its temporary file beside the destination, with a
non-image `.part` name, validates the result, and then installs it atomically.
Static copies and manual sources receive image-signature validation without
`ffmpeg`, plus full decode validation when it is present. A failed or
interrupted extraction never promotes the partial file to the stable export
path.

Without a cooperative W Engine capture adapter, Wall-in-One does **not** claim
to capture the active on-screen scene. It never scrapes process arguments or
starts a second renderer. Automatic W Engine export is off by default and only
runs when a cooperative status adapter reports a changed Workshop item.

The optional W Engine adapter v1 handshake advertises `status` and/or `capture`
capabilities to `goober/wall-in-one:coordinator`. A status-capable adapter
reports the current numeric Workshop ID per output. For each rendered-capture
request, Wall-in-One creates a unique requested PNG path under
`pluginDataDir()/staging`. The capture-capable adapter owns the capture, writes
that PNG atomically, and must return **exactly the requested path**. Alternate
paths, stale replies, missing files, and mismatched request IDs are rejected;
Wall-in-One validates the accepted staging PNG before exporting it.

Rendered adapter capture is used only when optional `ffmpeg` is present to
decode-validate that returned PNG. Without it, Wall-in-One does not weaken the
adapter boundary or trust a filename alone; it falls back to the configured
Workshop source or preview path.

The adapter frame delay is limited to 1–120 frames. Its request deadline is
`max(60 seconds, frame delay + 60 seconds)`, so a configured capture delay does
not consume the response allowance. Providers without the handshake remain
fully usable through the configured-ID source/preview fallback. The wire
contract and existing provider capability table are in
[ADAPTERS.md](ADAPTERS.md).

After each successful enabled-plugin discovery, Wall-in-One sends
`wall-in-one-probe-v1` to `tadomika_ari/w-engine:start`. A v1 adapter must then
re-send its `provider-capabilities-v1` announcement and current
`provider-current-v1` state. If no response newer than that probe arrives
within 10 seconds, Wall-in-One clears the stale adapter version, capabilities,
and current-output flags. The ordinary W Engine panel and public controls stay
available, and still export returns to the configured Workshop
source/preview fallback instead of trusting stale state.

## Static pairing and color sync

**Export + pair** and **Pair selected still** call Noctalia's public
`setWallpaper` runtime API for the target output. The image therefore becomes
Noctalia's persisted wallpaper while the live provider continues rendering
above it. Pairing does not disable Noctalia's wallpaper surface and does not
start or stop the live provider.

Color synchronization is an independent opt-in and defaults off. When enabled,
pairing sets Noctalia's global color source to `wallpaper` with the selected
scheme. If the existing color source is already `wallpaper`, Noctalia may
naturally regenerate colors from a newly paired image even while this toggle is
off; the toggle is not a palette-freeze control.

Noctalia has one global palette, not one palette per output. Set **Global
palette leader output** to a connector name when one output's paired still
should deterministically win. If it is empty, the most recently applied pair
wins.

An explicit lock-screen wallpaper path overrides Noctalia's ordinary persisted
wallpaper. If the lock screen does not follow a new pair, clear or update that
override in Noctalia settings. Wall-in-One never mutates it silently.

## Installation and IDs

After adding this repository as a Noctalia v5 plugin source, enable
`goober/wall-in-one`. Place either or both UI entries through Noctalia settings:

- widget: `goober/wall-in-one:wall-in-one`
- Control Center shortcut: `goober/wall-in-one:wall-in-one-shortcut`
- attached hub panel: `goober/wall-in-one:hub`
- coordinator service: `goober/wall-in-one:coordinator`

Open the hub from a terminal when needed:

```bash
noctalia msg panel-toggle goober/wall-in-one:hub
```

Useful service IPC events include `probe`, `next`, `previous`, `random`,
`capture`, `capture-pair`, `capture-video`, `capture-video-pair`, `pair-manual`,
`w-engine-next`, `w-engine-cycle-stop`, `w-engine-stop`, `mpvpaper-pause`,
`mpvpaper-resume`, `mpvpaper-toggle`, `mpvpaper-clear`, and
`mpvpaper-clear-all`.

The old `w-engine-pause` event remains an input alias for compatibility with
early Wall-in-One builds; new integrations should send
`w-engine-cycle-stop`, which matches W Engine's actual public event.

## Stored state and upgrades

Gesture configuration uses schema 1 and current runtime observations use
schema 2. On first load after upgrading, a valid schema-1 `runtime.json` is
migrated to schema 2 and installed atomically; the previous valid document is
retained as the last-known-good backup. Corrupt documents and unknown schema
versions still fail closed instead of being silently reset.

## Current scope

Wall-in-One coordinates existing provider rotations, but a single mixed,
timed static/live scheduler is not implemented yet. It also does not emulate
Wallpaper Engine, control scene properties, or invent a generic private API for
plugins. Those refinements need explicit lifecycle and provider contracts.

## Validation

```bash
noctalia plugins lint wall-in-one
python3 wall-in-one/tests/test_contract.py
```

See [TESTING.md](TESTING.md) and the repository's
[`tests/manual/wall-in-one.md`](../tests/manual/wall-in-one.md) for the full
capability and pairing matrix.
