# Wall-in-One provider adapters

Wall-in-One discovers enabled plugins from `noctalia msg plugins list` and uses
only public panels or documented service events. Noctalia v5 does not expose
another plugin's state, so enabled and ready are deliberately separate states.

## Built-in provider registry

| Provider | Public integration |
| --- | --- |
| Noctalia | Wallpaper panel and `wallpaper-next`, `wallpaper-previous`, and `wallpaper-random` |
| Wallhaven | `noctalia/wallhaven:browser` panel |
| W Engine | Panel plus `next`, `cycle-stop`, and `stop` on `tadomika_ari/w-engine:start` |
| mpvpaper | Picker plus `pause`, `resume`, `toggle`, `clear`, and `clear-all` on `noctalia/mpvpaper:service` |
| Custom | A user-configured full `author/plugin:panel` ID, open-only |

The current W Engine and mpvpaper releases do not publicly report the active
source or return data from their service IPC. Wall-in-One therefore never reads
their private state, PID files, process arguments, or caches.

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
