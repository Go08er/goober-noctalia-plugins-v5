# Wallpaper Director Hub test record

Target: Noctalia `5.0.0-beta.7` / plugin API 17.

## Automated checks

- `noctalia plugins lint wallpaper-director`
- `python3 wallpaper-director/tests/test_contract.py`
- Luau formatting check with StyLua
- Repository static validation after the root catalog row is added

The local contract test pins the four entry types, all default mappings, public
provider panel IDs, canonical native wallpaper IPC verbs, and the absence of
live-process/private-state ownership calls.

## Manual Hub matrix

| Case | Expected result |
|---|---|
| First left/middle/right click | Opens native selector / Wallhaven / W Engine respectively when providers are available |
| Wallhaven disabled | Saved middle mapping remains visible as unavailable; click performs no fallback |
| W Engine disabled | Saved right mapping remains visible as unavailable; no renderer is launched |
| W Engine enabled, renderer missing | Provider card distinguishes the missing command; action is blocked |
| Reassign each bar gesture | Mapping persists through panel close and plugin reload |
| Native next/previous/random | Uses the matching fixed Noctalia IPC command on the invoking output |
| Provider probe fails or times out | Optional actions are unavailable, diagnostics show one bounded error, native selector remains available |
| Corrupt config/runtime JSON | Stored file is not reset; action routing fails disabled and Diagnostics reports the file |
| Multiple bar placements | One service probes providers; each click opens from its own widget caller |
| Control Center tile | Left/right use their matching mappings; no middle or scroll substitute appears |
| Reload/disable | No `linux-wallpaperengine` process is started, stopped, or signalled |

## Deferred checks

Pair generation, capture, surface suppression/restore, static reels, W Engine
adapter calls, and mixed reels are intentionally outside v0.1.0. Their controls
must remain informational until the matching lifecycle and provider contracts
exist.
