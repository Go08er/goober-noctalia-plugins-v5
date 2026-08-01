# NocVox manual test

Target: Noctalia 5.0.0-beta.7 or newer and VoxType 0.7.5. VoxType must already
be configured and its daemon must remain owned by the user's normal service or
session configuration.

## Safety setup

1. Record the daemon PID and service state before enabling the plugin.
2. Add two `goober/nocvox:nocvox` placements with visibly different
   labels, glyphs, colors, and gesture mappings.
3. Keep transition notifications off for the first pass.

At no point should the plugin invoke `voxtype daemon`, `systemctl`, setup,
installation, model downloads, or configuration mutation.

## State and controls

| Case | Expected result |
|---|---|
| Daemon stopped externally | Widget shows unavailable/stopped; clicking toggle does not start the daemon |
| Daemon running and idle | One status follower serves both widgets; left toggle starts recording |
| Recording or streaming | Live state appears on both widgets; toggle stops recording |
| Transcribing | Processing state is visible; start/stop/toggle is unavailable |
| Recording, streaming, or transcribing | Configured cancel gesture sends one cancel request |
| Plugin enabled during recording | Active state appears; elapsed time is marked approximate/unknown |
| Command failure | One bounded error appears and the follower continues updating |

Verify the daemon PID is unchanged after every row.

## Customization and panel

1. Open each widget's settings and use Noctalia's searchable glyph selector for
   idle, active, stopped, and unknown glyphs.
2. Exercise left, middle, and right mappings for toggle, start, stop, cancel,
   panel, and no action. Invalid-for-state actions must explain why they are
   unavailable.
3. Open the attached details panel from each placement. It should anchor to the
   invoking widget and show the same live state as the bar.
4. Run diagnostics once. Confirm version and variant information appears only
   after the request and is not continuously polled.

## One-shot output checks

Enable advanced one-shot overrides deliberately, then test:

- Type, Clipboard, Paste, and an absolute File path containing spaces.
- Each tri-state option in inherit/on/off mode.
- A rejected relative file path and rejected punctuation in model/profile
  fields; rejection must launch no recording command.
- Stop after a Type/Clipboard/Paste start; the matching stop output flag should
  be retained for that recording only.

Clipboard mode is an output choice, not transcript history. The plugin must not
poll the clipboard, scrape notifications, or retain unrelated clipboard data.

## Lifecycle

1. Reload the widget, panel, and service while idle, then while recording.
2. Confirm there is only one `voxtype status --follow` owner after each reload.
3. Disable and uninstall the plugin. Its follower must exit promptly, while the
   original daemon PID and service state remain unchanged.

The deterministic headless equivalent is
[`tests/vm/nocvox.nix`](../vm/nocvox.nix). Once exported by the flake, run it
as `nix build -L .#vm-test-nocvox`.
