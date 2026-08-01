# NocVox test record

The automated check is intentionally local and non-mutating:

```bash
python3 nocvox/tests/check.py
noctalia plugins lint nocvox
```

It verifies the entry IDs, API level, native `toggle / widget settings / details`
action layout, widget-only presentation settings, translation coverage, exact
fixed recording commands, exactly one status follower, and the absence of
notifications, per-recording overrides, daemon lifecycle, configuration,
filesystem persistence, clipboard-reading, and transcript-history operations.

## Manual matrix

Run these after enabling the plugin through Noctalia's normal plugin UI. Do not
edit `settings.toml` or the materialized plugin copy.

| Case | Expected result |
|---|---|
| Existing daemon is idle | Microphone glyph updates immediately from the status stream; left click starts recording. |
| Existing daemon is recording/streaming | Widget turns to the recording color; left click stops and transcribes. |
| Middle click | Noctalia opens this placement's widget editor, including appearance, glyph pickers, and Actions. |
| Right click | The attached details panel opens with Start/Stop/Cancel, status, and diagnostics. |
| `Ctrl+Control_R` outside Noctalia | The same widget follows the resulting state without polling. |
| Daemon is stopped | The panel shows only the bounded external-management explanation, widget-settings hint, and Close control. |
| `voxtype` is absent | The widget/panel report the missing executable; no fallback command runs. |
| Malformed status line | The listener records a bounded error without crashing or logging the raw line. |
| Two widget placements | Both consume the one service state; only one `voxtype status --follow` process exists. |
| Plugin reload/disable | Noctalia terminates the one follower; VoxType daemon state is untouched. |
| Rebound native action | The selected v5 action remains scoped to that widget placement and dispatches at most one service command. |
| Start/stop/cancel | Each control launches its exact fixed `voxtype record` command with no added per-recording flags. |
| State or action failure | The bounded error stays in the widget/panel; NocVox emits no desktop notification. |
| Diagnostics | `voxtype --version` and `voxtype info variants --json` run only on demand; copied text contains no speech/transcript/log/clipboard data. |

The daemon-changing click cases should be exercised only in a disposable test
session or with the user deliberately controlling a real recording. Static
validation never invokes `voxtype record`, daemon lifecycle, or config commands.
