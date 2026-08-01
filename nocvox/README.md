# NocVox

NocVox is a native Noctalia v5 status-and-control companion for an
already installed, configured, and independently managed
[VoxType](https://github.com/peteonrails/voxtype) daemon. It provides one live
status listener, a customizable bar widget, and an attached details/diagnostics
panel.

This is a conservative `0.1.0` MVP for Noctalia `5.0.0-beta.7` and VoxType
`0.7.5`. It targets plugin API 17 so its singleton service starts on an explicit
plugin enable in that Noctalia release.

## Hard boundary

The plugin is a listener and recording-control client only. It never:

- installs, starts, stops, restarts, supervises, or updates the VoxType daemon;
- runs VoxType setup/configuration commands or edits `config.toml`;
- replaces compositor keybinds, including `Ctrl+Control_R`;
- reads logs, audio, clipboard contents, or transcript text;
- creates transcript history or clipboard backups;
- creates, edits, or deletes VoxType models or profiles.

The only long-lived child is one read-only status follower:

```text
voxtype status --follow --format json --extended --icon-theme text
```

Noctalia owns that child and terminates it when the service entry reloads or is
disabled. The plugin has no command that changes daemon lifecycle.

## Entries

| Entry | ID | Responsibility |
|---|---|---|
| Service | `goober/nocvox:listener` | Owns the single status stream, state normalization, safe recording commands, and on-demand diagnostics. |
| Widget | `goober/nocvox:nocvox` | Renders status and forwards configured gestures to the service. |
| Panel | `goober/nocvox:details` | Shows supported controls, optional one-shot choices, and privacy-safe diagnostics. |

Entries exchange plain state through `noctalia.state`; no widget placement owns
another follower. This follows Noctalia's documented
[shared-state and stream lifecycle](https://docs.noctalia.dev/v5/plugins/development/runtime-api/)
model.

## Default gestures

The defaults preserve the previous custom button behavior:

| Gesture | Default |
|---|---|
| Left click | State-aware toggle: idle starts; recording/streaming stops and transcribes. |
| Middle click | Cancel/discard the current recording or transcription. |
| Right click | Cancel/discard the current recording or transcription. |

Noctalia normally reserves middle click to open widget settings, so this plugin
declares the v5 `middle = "none"` action to free the callback. All three
gestures can independently be changed in the widget editor to Toggle, Start,
Stop and transcribe, Cancel, Open/close details, or No action. A saved action is
never silently replaced when it is unavailable; its tooltip explains the
current state restriction.

To keep all three defaults and still open the panel, either assign one gesture
to **Open/close details** or run:

```bash
noctalia msg panel-toggle goober/nocvox:details
```

## Live presentation

The widget understands `stopped`, `idle`, `recording`, `streaming`,
`transcribing`, legacy/future `processing`, `error`, and unknown/malformed
states. It uses Noctalia palette roles rather than fixed colors. Widget settings
provide:

- glyph-only, `IDLE`, or hidden idle behavior;
- `REC`, local approximate elapsed time, or glyph-only active labels;
- compact or expanded state text;
- optional active one-shot label;
- native v5 glyph selectors for idle, active, stopped, and unknown states;
- theme-token colors and model/device/backend tooltip visibility.

An elapsed value prefixed with `~` means the listener attached after recording
had already begun. Metadata reported by `status --extended` describes configured
values; it is not proof of the resolved microphone or accelerator. A reported
backend of `unknown` is displayed as-is.

When the daemon is stopped, the details panel deliberately stops at a bounded
explanation plus Settings/Close controls. It does not offer lifecycle buttons.

## Optional one-shot recording overrides

Advanced overrides are disabled by default. When explicitly enabled in plugin
settings, pressing **Start recording** in the details panel may pass only the
arguments supported by VoxType `0.7.5`:

- exclusive output destination: daemon default, keyboard type, clipboard,
  paste, or file;
- an optional existing model name;
- an optional existing profile name;
- inherit/on/off values for auto-submit, Shift+Enter newlines, and smart
  auto-submit.

Model and profile strings are syntax-validated, quoted, and passed as one-shot
references. VoxType remains authoritative for whether those existing names are
available; the plugin performs no discovery that mutates configuration and
never creates a profile.

File output is exclusive for that recording. It requires an absolute path or a
path beginning with `~/`; control characters and overlong paths are rejected,
the home prefix is expanded by Noctalia, and the complete `--file=...` argument
is shell-quoted. The plugin does not delete or back up the selected file.

Clipboard and paste are also one-shot **output destinations**, not history.
NocVox never calls the clipboard-read API and never scrapes, archives,
restores, or backs up clipboard/transcript contents. That means the originally
suggested “keep a backup of output in clipboard” feature is intentionally not
implemented: ordinary dictation exposes no trustworthy transcript-history API,
and guessing from the clipboard would violate the privacy boundary.

For deterministic output behavior, Stop repeats only the active
`--type`/`--clipboard`/`--paste` flag that VoxType supports at stop time. File,
model, profile, and text-processing choices are supplied only to Start.

## Diagnostics

The panel runs these read-only commands only when **Run diagnostics** is pressed:

```text
voxtype --version
voxtype info variants --json
```

It shows install kind, compiled features, CPU/GPU detection, and VoxType's own
recommendation. **Copy safe summary** copies only those build facts plus current
status metadata. It never includes speech, transcripts, audio, logs, or prior
clipboard contents.

## Installation and configuration

Use Noctalia's normal source/plugin UI and then place the VoxType widget through
the bar editor. Installing does not enable or place it automatically. The plugin
does not edit Noctalia's imperative settings file or files under
`plugins/materialized`.

The manifest uses the current v5
[manifest/settings schema](https://docs.noctalia.dev/v5/plugins/development/manifest/).
Plugin-wide notification, tooltip, color, and advanced-override settings live
under Settings → Plugins. Gesture, label, width, and glyph choices are per bar
placement in the widget editor.

## Validation

From the repository root:

```bash
python3 nocvox/tests/check.py
noctalia plugins lint nocvox
```

The static check asserts the privacy/ownership boundaries and the single-stream
architecture without invoking any recording command. The manual acceptance
matrix is in [`tests/README.md`](tests/README.md).

## Known MVP limits

- VoxType status does not expose transcript text, audio level, partial text,
  detected language, resolved microphone name, active output mode, or detailed
  transcription failures; the plugin does not invent them.
- Noctalia beta.7's process `runStream` has no exit callback. This MVP launches
  its follower once and never enters a respawn loop. If the follower itself
  unexpectedly exits, reload the plugin after resolving the cause.
- Override selections are intentionally ephemeral and reset on plugin reload;
  the daemon's configured defaults remain authoritative.
- Meeting management, global engine/model/device changes, and setup/update
  operations remain outside this companion.

## License

MIT
