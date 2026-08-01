# NocVox manual test

Target: Noctalia 5.0.0 or newer and VoxType 0.7.5. VoxType must already
be configured and its daemon must remain owned by the user's normal service or
session configuration.

## Safety setup

1. Record the daemon PID and service state before enabling the plugin.
2. Add two `goober/nocvox:nocvox` placements with visibly different
   labels, glyphs, colors, and gesture mappings.

At no point should the plugin invoke `voxtype daemon`, `systemctl`, setup,
installation, model downloads, configuration mutation, or desktop
notifications.

## State and controls

| Case | Expected result |
|---|---|
| Daemon stopped externally | Widget shows unavailable/stopped; clicking toggle does not start the daemon |
| Daemon running and idle | One status follower serves both widgets; left toggle starts recording |
| Recording or streaming | Live state appears on both widgets; toggle stops recording |
| Transcribing | Processing state is visible; start/stop/toggle is unavailable |
| Recording, streaming, or transcribing | Configured cancel gesture sends one cancel request |
| Plugin enabled during recording | Active state appears; elapsed time is marked approximate/unknown |
| Command failure | One bounded inline error appears and the follower continues updating |

Verify the daemon PID is unchanged after every row.

## Customization and panel

1. Open each widget's settings and use Noctalia's searchable glyph selector for
   idle, active, stopped, and unknown glyphs.
2. Confirm the native Actions section shows left-click toggle and right-click
   details defaults while middle click initially retains Noctalia's
   widget-settings action. Rebind a spare gesture to plugin event `cancel`; an
   invalid-state action must be rejected without launching a different command.
3. Right-click each placement to open the attached details panel. It should
   anchor to the invoking widget and show the same live state as the bar.
4. Run diagnostics once. Confirm version and variant information appears only
   after the request and is not continuously polled.

## Command boundary

Capture the launched commands while exercising the controls. Start, Stop, and
Cancel must issue exactly `voxtype record start`, `voxtype record stop`, and
`voxtype record cancel`, with no output, model, profile, or text-action flags.
VoxType's configured defaults remain authoritative. Confirm state changes,
action failures, diagnostics, and diagnostic-copy results produce no desktop
notifications.

## Lifecycle

1. Reload the widget, panel, and service while idle, then while recording.
2. Confirm there is only one `voxtype status --follow` owner after each reload.
3. Disable and uninstall the plugin. Its follower must exit promptly, while the
   original daemon PID and service state remain unchanged.

The deterministic headless equivalent is
[`tests/vm/nocvox.nix`](../vm/nocvox.nix). Once exported by the flake, run it
as `nix build -L .#vm-test-nocvox`.
