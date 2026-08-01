# NocVox

NocVox is a native Noctalia v5 status-and-control companion for an
already installed, configured, and independently managed
[VoxType](https://github.com/peteonrails/voxtype) daemon. It provides one live
status listener, a customizable bar widget, and an attached details/diagnostics
panel.

This is a conservative `0.3.0` companion for Noctalia `5.0.0` and VoxType
`0.7.5`. It targets plugin API 17 so its singleton service starts when the
plugin is enabled.

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
| Widget | `goober/nocvox:nocvox` | Renders status and exposes native per-placement actions and presentation settings. |
| Panel | `goober/nocvox:details` | Shows supported controls, live status details, and privacy-safe diagnostics. |

Entries exchange plain state through `noctalia.state`; no widget placement owns
another follower. This follows Noctalia's documented
[shared-state and stream lifecycle](https://docs.noctalia.dev/v5/plugins/development/runtime-api/)
model.

## Controls and default actions

Recording operations are collected in the attached details panel: Start, Stop
and transcribe, Cancel/discard, live status, and privacy-safe diagnostics. The
bar widget uses Noctalia's native per-placement **Actions** editor rather than a
second set of NocVox gesture dropdowns:

| Gesture | Default |
|---|---|
| Left click | State-aware toggle: idle starts; recording/streaming stops and transcribes. |
| Middle click | Open this widget placement's settings, Noctalia's standard default. |
| Right click | Open/close the attached NocVox details panel. |

The manifest defaults are ordinary v5 action commands:

```toml
[widget.actions]
left = "plugin goober/nocvox:listener all toggle"
right = "panel-toggle goober/nocvox:details"
```

They appear in the same Actions section as every built-in widget binding and
can be replaced per placement. For example, bind a spare gesture to
`plugin goober/nocvox:listener all cancel` for immediate cancel/discard. The
details panel can also be opened directly:

```bash
noctalia msg panel-toggle goober/nocvox:details
```

## Live presentation

The widget understands `stopped`, `idle`, `recording`, `streaming`,
`transcribing`, legacy/future `processing`, `error`, and unknown/malformed
states. It uses Noctalia palette roles rather than fixed colors. Every
presentation option is per bar placement in that widget's settings:

- glyph-only, `IDLE`, or hidden idle behavior;
- `REC`, local approximate elapsed time, or glyph-only active labels;
- compact or expanded state text;
- native v5 glyph selectors for idle, active, stopped, and unknown states;
- theme-token colors and model/device/backend tooltip visibility.

An elapsed value prefixed with `~` means the listener attached after recording
had already begun. Metadata reported by `status --extended` describes configured
values; it is not proof of the resolved microphone or accelerator. A reported
backend of `unknown` is displayed as-is.

When the daemon is stopped, the details panel deliberately stops at a bounded
explanation plus the Close control. It does not offer lifecycle buttons.

## Recording commands

NocVox deliberately uses VoxType's configured defaults. Its control surface
issues only these fixed commands:

```text
voxtype record start
voxtype record stop
voxtype record cancel
```

There is no per-recording override builder, output selector, model/profile
selector, transcript history, or clipboard backup. Output and text-processing
behavior belong in VoxType's own configuration. NocVox also emits no desktop
notifications; live state and bounded failures stay in its widget, tooltip, and
panel.

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

The manifest follows the current v5
[settings scopes](https://docs.noctalia.dev/v5/plugins/development/manifest/):
settings needed by a service or panel are plugin-wide, while bar appearance is
per widget placement. NocVox's listener has no configurable global policy, so
NocVox declares no root settings. Its organization is therefore:

- right-click the widget for recording controls, live status, and diagnostics;
- by default, middle-click the widget for its labels, tooltip fields, colors,
  glyph pickers, and native Actions section;
- use Settings → Plugins for plugin source, enable, and update state. NocVox has
  no global preference page because its listener has no configurable policy.

This separation is a Noctalia convention rather than a glyph limitation. The
native searchable glyph picker is tied to widget-entry settings in the current
v5 UI, which is also the correct scope for a bar icon.

When upgrading from `0.2.x`, reselect any customized tooltip/color values in
each widget placement. The former root keys (`tooltip_show_*` and the five
`*_color` keys) are no longer declared globally. Along with the already removed
`notify_transitions`, `notify_failures`, `enable_one_shot_overrides`, and
`show_override_name` keys, stale root values have no effect and can be removed
during normal settings cleanup if Noctalia reports them as unknown.

The former per-widget `left_action`, `middle_action`, and `right_action` select
keys are also obsolete. They cannot be translated automatically because v5's
native Actions editor accepts any supported Noctalia action command, not just
NocVox's old fixed choices. Remove those stale keys and recreate any custom
bindings in each placement's **Actions** section. For a placement named
`nocvox-a`, the equivalent persisted shape is:

```toml
[widget.nocvox-a.actions]
left = "plugin goober/nocvox:listener all toggle"
right = "panel-toggle goober/nocvox:details"
# Leave middle unset for Noctalia's settings-open-widget default, or bind it:
# middle = "plugin goober/nocvox:listener all cancel"
```

Use the widget editor for normal migration; the TOML above documents the mapping
for users who maintain their Noctalia settings declaratively.

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
- Noctalia's process `runStream` has no exit callback. This companion launches
  its follower once and never enters a respawn loop. If the follower itself
  unexpectedly exits, reload the plugin after resolving the cause.
- Meeting management, global engine/model/device changes, and setup/update
  operations remain outside this companion.

## License

MIT
