# VoxType Suite test record

The automated check is intentionally local and non-mutating:

```bash
python3 voxtype-suite/tests/check.py
noctalia plugins lint voxtype-suite
```

It verifies the entry IDs, API level, default `toggle / cancel / cancel`
gestures, translation coverage, disabled-by-default overrides, exactly one
status follower, and the absence of daemon lifecycle, configuration, filesystem
persistence, clipboard-reading, and transcript-history operations.

## Manual matrix

Run these after enabling the plugin through Noctalia's normal plugin UI. Do not
edit `settings.toml` or the materialized plugin copy.

| Case | Expected result |
|---|---|
| Existing daemon is idle | Microphone glyph updates immediately from the status stream; left click starts recording. |
| Existing daemon is recording/streaming | Widget turns to the recording color; left click stops and transcribes. |
| Middle or right click while active | Current recording/transcription is cancelled and discarded. |
| `Ctrl+Control_R` outside Noctalia | The same widget follows the resulting state without polling. |
| Daemon is stopped | The panel shows only the bounded external-management explanation and close/settings controls. |
| `voxtype` is absent | The widget/panel report the missing executable; no fallback command runs. |
| Malformed status line | The listener records a bounded error without crashing or logging the raw line. |
| Two widget placements | Both consume the one service state; only one `voxtype status --follow` process exists. |
| Plugin reload/disable | Noctalia terminates the one follower; VoxType daemon state is untouched. |
| Saved unavailable gesture | The setting remains unchanged and its tooltip explains why it cannot run. |
| Overrides disabled | Panel offers no override controls; normal recording uses daemon defaults. |
| Clipboard/paste override | VoxType receives that one-shot destination; the plugin never reads or backs up clipboard content. |
| File override | A relative/control-character path is rejected; an absolute or `~/` path is safely quoted and is the exclusive output. |
| Diagnostics | `voxtype --version` and `voxtype info variants --json` run only on demand; copied text contains no speech/transcript/log/clipboard data. |

The daemon-changing click cases should be exercised only in a disposable test
session or with the user deliberately controlling a real recording. Static
validation never invokes `voxtype record`, daemon lifecycle, or config commands.
