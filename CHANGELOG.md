# Changelog

All notable staging changes will be recorded here.

## Wallpaper Director 0.1.0 - Hub MVP

- Add an API 17 singleton routing service, three-button bar widget, attached
  configuration/diagnostics panel, and left/right Control Center shortcut.
- Detect enabled Wallhaven and W Engine providers asynchronously while keeping
  native wallpaper selection and fixed next/previous/random IPC available.
- Persist schema-versioned gesture mappings atomically, retain saved unavailable
  actions, and fail disabled instead of replacing corrupt user data.
- Preserve ownership boundaries: this phase never launches
  `linux-wallpaperengine`, reads W Engine private state, suppresses Noctalia's
  wallpaper surface, or starts a competing scheduler.
- Stage pairing, generated stills, curated reels, and mixed live/static policy
  behind future Noctalia lifecycle and W Engine adapter work.

## VoxType Suite 0.1.0 - Companion MVP

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
