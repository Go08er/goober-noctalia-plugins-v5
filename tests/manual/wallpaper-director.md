# Wallpaper Director manual test

Target: Noctalia 5.0.0-beta.7 or newer. Wallhaven and W Engine are optional;
test each availability combination rather than installing them solely for this
check.

## Provider matrix

| Wallhaven | W Engine plugin | `linux-wallpaperengine` | Expected result |
|---|---|---|---|
| Off | Off | Missing | Native controls work; saved optional mappings remain visible as unavailable |
| On | Off | Missing | Wallhaven opens; W Engine remains unavailable |
| Off | On | Missing | W Engine card reports the missing renderer and launches nothing |
| On | On | Present | Both public provider panels open; Director still owns no live process |

After changing a provider, request a probe. Availability must follow the exact
`noctalia msg plugins list` enabled marker, with no fallback or silent gesture
remapping.

## Hub and customization

1. Add two `goober/wallpaper-director:wallpapers` widgets with different glyph,
   label, visibility, and color settings. Exercise Noctalia's searchable glyph
   selector for each placement.
2. Confirm default bar gestures open the native selector, Wallhaven browser,
   and W Engine panel when available.
3. Reassign all three gestures in the Director panel, close it, reload the
   service, and restart Noctalia. The mappings must persist unchanged.
4. Open native, Wallhaven, W Engine, and Director panels from each bar
   placement. Attached panels should follow the invoking widget.
5. Test native next, previous, and random on each connected output. Director
   must use Noctalia's fixed wallpaper IPC verbs and never accept an arbitrary
   command or output name.
6. Add the Control Center shortcut. Left and right actions should follow their
   mappings; no middle-click substitute should appear.

## Persistence and failure handling

Inspect the plugin data directory after two mapping changes:

- `config.json` and `runtime.json` use `schema_version = 1`.
- `config.json.bak` contains the previous valid mapping.
- No `.tmp` file remains after a successful write.

Back up the files, then test malformed JSON. Diagnostics should report the
invalid file, routing should fail closed, and the stored evidence must not be
silently replaced. Restore the backup before continuing.

## Ownership and lifecycle

Record any running `linux-wallpaperengine` PIDs and W Engine's current scene.
Reload, disable, and uninstall Director. Confirm that it:

- starts, stops, or signals no live-wallpaper process;
- does not write W Engine's private plugin-data directory;
- does not suppress or restore Noctalia's native wallpaper surface; and
- leaves the recorded PIDs and scene unchanged.

Static/live pairing, capture, timed reels, Wallhaven feed automation, mixed
reels, and automatic native/live conflict resolution are deferred. Their UI
must remain explanatory rather than performing partial lifecycle operations.

The deterministic headless equivalent is
[`tests/vm/wallpaper.nix`](../vm/wallpaper.nix). Once exported by the flake, run
it as `nix build -L .#vm-test-wallpaper`.
