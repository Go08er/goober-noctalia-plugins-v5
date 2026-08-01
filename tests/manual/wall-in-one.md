# Wall-in-One manual test

Target: Noctalia 5.0.0-beta.7 or newer. Run provider combinations in an
isolated session or VM; do not install optional providers solely to make a card
green.

## Provider discovery and controls

| Wallhaven | W Engine | W Engine adapter | mpvpaper | Expected result |
|---|---|---|---|---|
| Off | Off | None | Off | Native controls and validated manual pairing work; configured-video export works when optional ffmpeg is installed |
| On | Off | None | Off | Wallhaven browser opens; no library state is imported |
| Off | On | None | Off | W Engine panel/control IPC works; only configured-ID fallback export is offered |
| Off | On | Status | Off | Adapter-reported Workshop ID appears for the matching output |
| Off | On | Status + capture | Off | UI reports adapter support; optional ffmpeg enables rendered capture validation, otherwise export uses source/preview fallback |
| Off | Off | None | On | mpvpaper picker and documented service controls work |

Disable a discovered plugin and refresh capabilities. Its saved gesture must
remain visible as unavailable and must not fall back to another action. A
configured custom `vendor/plugin:panel` must follow the same rule.

For an adapter-enabled W Engine, each successful provider refresh must send
`wall-in-one-probe-v1`. Have the adapter re-send `provider-capabilities-v1` and
the current `provider-current-v1` records; the UI should retain the fresh
capabilities and output IDs. Then suppress that response and refresh again.
After 10 seconds the stale adapter flags and current IDs must disappear, while
the W Engine panel/public controls remain available and capture returns to the
configured Workshop source/preview fallback.

For W Engine without an adapter, verify there is no process-argument scraping,
second renderer, active-frame claim, or private plugin-data access. A configured
numeric Workshop item should export a real `ffmpeg` frame for video projects or
the Workshop preview for scene/web projects.

## Hub and customization

1. Add two `goober/wall-in-one:wall-in-one` widgets with different glyph,
   label, visibility, and color settings. Exercise Noctalia's native searchable
   glyph selector for each placement.
2. Confirm the default bar gestures open the native selector, Wallhaven, and W
   Engine when available.
3. Reassign every provider control, configured-video export, W Engine export,
   manual pair, and `Open Wall-in-One` across the three gestures. Reload the
   plugin and confirm mappings persist.
4. Open provider panels from both widgets. Attached panels should follow the
   invoking placement.
5. Test native previous/random/next on each output, W Engine next/cycle-stop/stop,
   and mpvpaper pause/resume/toggle/clear/clear-all. For direct coordinator IPC,
   use `w-engine-cycle-stop`; `w-engine-pause` is only a compatibility alias for
   early Wall-in-One clients.
6. Add the Control Center shortcut. Left and right mappings work; no middle
   callback substitute appears.

## Still export and pairing

1. Leave the destination empty and export a static preview. Confirm the stable
   image lands under Wall-in-One's `pluginDataDir()/captures`. Then select an
   absolute destination directory and confirm subsequent exports move there.
   Enter a relative path through a fixture or stored setting and confirm it is
   rejected rather than resolved against the service working directory.
2. Select a short video. With optional `ffmpeg` installed, export at frame 0
   and a later frame; validate both images and confirm stable destination names.
3. Use **Export + pair configured video** per output. Confirm Noctalia persists
   the image while the live provider remains active above it.
4. Configure a numeric Workshop ID. For a video project validate an extracted
   source frame; for a scene/web project validate the copied preview and ensure
   the UI never calls it a rendered live frame.
5. With optional `ffmpeg` present and a cooperative capture adapter, confirm the
   active ID comes from the adapter and rendered capture is only advertised
   after the handshake. Each request must name a unique
   `pluginDataDir()/staging/*.png`; reject a stale request ID, an alternate
   returned path, or a missing result. Accept only when the adapter writes and
   returns the exact requested staging PNG and full decode validation succeeds.
6. Test adapter delays 1 and 120. Confirm values above 120 are rejected or
   clamped and that the response deadline is at least 60 seconds and extends to
   the configured delay plus 60 seconds.
7. Select a durable PNG/JPEG/WebP file and run **Pair selected still**. Confirm
   the helper checks its image signature before Noctalia is called, performs
   full decode validation when `ffmpeg` is available, and leaves the source
   unmodified. Only a temporary staging copy is allowed; no stable export copy
   may remain. Repeat with a truncated fake image; it must be rejected and the
   previous pair must remain intact.
8. During an export, confirm the helper's temporary output is beside the final
   destination, has a non-image `.part` name, and is atomically promoted only
   after validation. Interrupt it and confirm no partial destination or stale
   `.part` file remains.
9. Remove `ffmpeg`. Configured-video, Workshop-video, and animated-image frame
   extraction should show one bounded error, and cooperative rendered capture
   should safely use its Workshop source/preview fallback. Provider controls,
   static preview copies, image-signature validation, manual pairing, and
   existing-static-image pairing must remain usable. An unwritable destination
   must likewise leave the previous pair intact.

## Colors, lock screen, and multiple outputs

With color sync off, pair a still and confirm Wall-in-One does not issue a color
source change. If Noctalia was already using wallpaper colors, note that its
normal wallpaper application may still regenerate the palette.

Enable color sync and select each supported scheme. Pair again and confirm the
source becomes `wallpaper` with that scheme. On two outputs, set a palette
leader, pair the other output last, and verify the leader's still still wins the
single global palette.

Test both lock-screen configurations:

- no explicit lock-screen image: the paired persisted wallpaper follows;
- explicit lock-screen image: the override remains unchanged and the UI/docs
  explain that the user must clear or update it.

Also verify overview/backdrop, compositor blur/xray integrations, and wallpaper
hooks receive the persisted still path while live playback continues.

## Storage and lifecycle

After two mapping/pair changes, inspect plugin data:

- `config.json` is schema 1 and `runtime.json` is schema 2;
- `.bak` files contain the previous valid documents;
- no `.tmp` file remains after success.

Before that check, seed a valid schema-1 `runtime.json` and reload the plugin.
It must migrate atomically to schema 2, preserve the legacy document in the
last-known-good backup, and retain provider/pair observations. Reload once more
to confirm the migration does not run again.

Corrupt each JSON document in turn. Routing must fail closed, Diagnostics must
show the error, and the stored evidence must not be reset automatically.

Finally reload, disable, and uninstall Wall-in-One with both live providers
running. Confirm it neither signals their PIDs nor edits private provider state.
The paired static file and Noctalia wallpaper selection remain intact.

The headless equivalent is [`tests/vm/wall-in-one.nix`](../vm/wall-in-one.nix).
Once exported by the flake, run `nix build -L .#vm-test-wall-in-one`.
