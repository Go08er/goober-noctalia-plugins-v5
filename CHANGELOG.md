# Changelog

All notable staging changes will be recorded here.

## Hydra Update Examiner 0.4.0 - Native v5 settings scopes

- Keep the shared channel, poll interval, and readiness threshold in the plugin
  settings owned by the singleton service.
- Put text mode, colors, searchable glyph pickers, and native gesture actions
  together in each bar placement's widget editor.
- Remove the duplicated shared/local appearance controls and inheritance
  switches introduced during the initial v5 compatibility port.

## NocVox 0.3.0 - One widget configuration surface

- Move tooltip fields, state colors, labels, width, and glyphs into the placed
  widget's settings; the singleton listener has no global policy to configure.
- Replace the custom gesture dropdowns with native v5 Actions defaults: left
  toggles recording, right opens details, and middle opens widget settings.
- Remove the now-empty plugin-settings button from the details panel and point
  users to the exact per-placement editor instead.

## Wall-in-One 0.4.0 - Unified live library and mixed scheduler

- Add an API-17 internal renderer owner for `linux-wallpaperengine` and current
  mpvpaper, with exact child-PID supervision, hotplug-safe controls, bottom-layer
  playback, and complete `runStream` process-group teardown.
- Auto-browse local videos and Steam Wallpaper Engine Workshop projects; apply
  live sources only after generating or reusing a real Noctalia static pair.
- Add persistent per-output static/video/Workshop cycles with configurable
  interval, sequential/shuffle/random order, history, pause/resume, and manual
  navigation.
- Add a bounded MotionBGS HTML search/download provider with atomic local
  imports, source sidecars, explicit degraded status, and a permanent direct
  browser fallback.
- Preserve the official Wallhaven browser and external provider controls,
  default detected integrations on, and refuse internal renderer startup while
  another enabled plugin owns that backend.
- Move the default generated-still location to Noctalia's wallpaper directory
  and retain the complete color scheme, palette-leader, renderer, widget glyph,
  label, and gesture customization surface.

## NocVox 0.2.0 - Focused control companion

- Remove the per-recording output/model/profile/text-action override system.
  Start, stop, and cancel now always use the independently managed VoxType
  daemon's configured defaults.
- Remove all NocVox desktop notifications and their settings. State, action
  errors, diagnostic errors, and copy results remain visible in the widget or
  panel.
- Retain the singleton live-status follower, configurable gestures, native glyph
  selectors, palette controls, state-aware controls, and privacy-safe read-only
  diagnostics.

## Wall-in-One 0.3.0 - Provider policy and backing export

- Enable each detected Wallhaven, W Engine, mpvpaper, and custom-panel
  integration by default, with an independent Wall-in-One force-off that never
  disables, stops, or uninstalls the provider itself.
- Gate panels, controls, adapter probes, status, and W Engine capture routes on
  the effective detected-and-allowed provider state.
- Export the current per-output backing reported by Noctalia into the selected
  still directory. This safely saves a representative backing already supplied
  by W Engine without reading its private frame or thumbnail cache.
- Document that W Engine 1.1.0 already owns its timer, representative static
  backing, color handoff, and previous-wallpaper restoration. Wall-in-One does
  not duplicate that scheduler or take over its renderer.

## Wall-in-One 0.2.0 - Live/static coordination preview

- Rename the early wallpaper hub and its plugin, widget, panel, service, and
  Control Center IDs to `goober/wall-in-one`.
- Discover Wallhaven, W Engine, mpvpaper, and an optional open-only provider,
  while retaining Noctalia's native selector and next/previous/random routes.
- Route only documented provider panels and service commands; providers retain
  ownership of their renderers, files, and scheduling.
- Export full-resolution stills from a configured video or a configured W Engine
  Workshop project into a selected directory. Video projects use FFmpeg;
  scene/web projects use their preview until a cooperative capture adapter is
  present.
- Pair an exported still through `setWallpaper` so Noctalia persists a real
  image for its backdrop, hooks, lock-screen fallback, and wallpaper-derived
  colors while the dynamic provider remains active.
- Add selectable color-scheme synchronization and an optional palette-output
  leader for Noctalia's single global palette. Preserve explicit lock-screen
  wallpaper overrides instead of rewriting them.
- Define a versioned, opt-in W Engine status/capture handshake for rendered
  stills while keeping current upstream W Engine on safe video/preview fallback.
  Do not inspect process arguments or provider-private state, start a second
  renderer, or start a competing rotation scheduler.

## NocVox 0.1.0 - Companion MVP

- Add an API 17 singleton listener for the extended VoxType status stream with
  live idle, recording, streaming, transcribing, stopped, and unknown states.
- Add a configurable bar widget with native glyph selectors, default
  toggle/cancel/cancel gestures, an attached control/diagnostics panel, and
  state-aware action gating.
- Add disabled-by-default, validated one-shot output/model/profile/text-action
  overrides without editing or supervising the existing VoxType installation.
- Keep speech private: no transcript, audio, log, or clipboard content is read
  or persisted; clipboard/paste/file remain explicit VoxType output modes.

## Hydra Update Examiner 0.3.0 - Native glyph selection

- Make Noctalia's native searchable per-widget glyph picker the default through
  `use_shared_glyphs = false`.
- Decouple glyph inheritance from `use_shared_presentation`; shared readiness
  text and colors can now remain enabled while each placement chooses its own
  glyphs.
- Retain the four plugin-wide shared glyph names as an optional shared set for
  placements that explicitly enable **Use shared glyphs**. Current Noctalia v5
  renders root plugin glyph settings as text fields, so the native picker lives
  in the widget settings surface.
- Add adjacent-picker instructions, v0.2.0 migration guidance, and VM coverage
  that opens and captures the native **Pick a Glyph** menu.
- Normalize empty glyph values to valid state-specific defaults and pin both
  shared/local glyph-and-color inheritance combinations with VM render crops.

## Hydra Update Examiner 0.2.0 - Customization parity

- Restore all 13 v4-style controls to the plugin settings page as shared data
  and appearance defaults.
- Preserve v5 per-placement appearance controls behind an explicit **Use shared
  appearance** toggle, without hiding core color or glyph choices as Advanced.
- Restore hover-only readiness text through the native `onHover` callback.
- Add a native attached action panel with Refresh, Open Hydra, Plugin settings,
  and Documentation commands.
- Declare an overridable right-click action and target plugin API 15 for native
  gesture defaults and scoped settings opening.
- Add v4-to-v5 settings mapping and clearer plugin-versus-widget settings
  documentation.
- Pass the complete beta.7/API 15 VM integration gate with shared and override
  placements, hover rendering, the attached panel, documentation and scoped
  settings actions, all three hot-reload paths, screenshots, and clean
  shutdown.

## Hydra Update Examiner 0.1.0 - Public test candidate

- Start a native Noctalia v5 source repository layout.
- Publish the repository as a directly importable custom Git source and
  document Settings, CLI, declarative configuration, update, removal, and local
  path-development workflows.
- Exercise Git-source cloning, root-catalog discovery, and managed plugin
  materialization in the disposable beta.7 VM test.
- Port the QML host layer to a Luau service and bar widget.
- Convert v4 settings to typed TOML settings.
- Preserve the existing Hydra helper as the initial backend.
- Add stale-result handling, single-flight refreshes, validation, and CI staging.
- Update the manifest and catalog to the beta.3 `plugin_api = 3` compatibility
  gate and enforce translation-only setting labels and current catalog rules.
- Pass the beta.3 first-party linter/config validator and a temporary live host
  load of both the service and bar-widget entries.
- Move continuing native integration testing into a disposable NixOS VM using
  headless Sway, deterministic Hydra fixtures, IPC, hot reload, and a guest
  screenshot.
- Pass the complete beta.3/API 3 VM test, including native lint/config checks,
  the rendered `Launched` state, open action, both hot-reload paths, and clean
  shutdown without plugin or Luau errors.
- Update the source for current community validation rules, including nested
  lowercase translation keys and the documented thumbnail constraints.
- Pin the integration harness to Noctalia v5.0.0-beta.7 while intentionally
  retaining plugin API 3 as the oldest capability level used.
- Pass the complete beta.7/API 3 VM integration test on 2026-07-31.
