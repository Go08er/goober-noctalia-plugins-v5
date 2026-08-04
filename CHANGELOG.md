# Changelog

All notable staging changes will be recorded here.

## Repository validation

- Mirror the official v5 README, required-file, translation-segment, and tag
  contracts locally; keep per-plugin `LICENSE` files as an explicit additional
  repository policy rather than presenting them as an upstream requirement.
- Remove the artificial plugin-API ceiling so future positive API levels are
  accepted while capability-specific minimums remain enforced.
- Restructure the NocVox and Wall-in-One READMEs around the published Plugin,
  Usage, Requirements, and Settings sections, and document why Wall-in-One's
  isolated Luau entries cannot be split into ordinary imported modules yet.

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

## Unreleased — Wall-in-One 0.7.1

- Keep full panel rendering out of `onFrameTick`; frame callbacks now advance
  only one bounded drag or preview-cache state-machine step. Memoize provider
  preview validation per result generation and render 36–48-result responses as
  fixed 12-card local pages.
- Add a host VM regression with 36 MotionBGS results, sustained frame delivery,
  bounded preview diagnostics, and explicit rejection of callback CPU-budget or
  panel-disable log records.
- Put Wallhaven downloads and MotionBGS HD/4K choices directly on result cards.
  Show downloading, queued, and already-on-disk state from provider status plus
  the managed library, reject exact duplicates, and retain a compact MotionBGS
  queue summary without claiming unavailable byte-level progress.
- Remove duplicated selected-item hero cards, full result URLs, long scraper
  implementation narration, and the MotionBGS helper's absolute filesystem path
  from the main shop surface. Keep detailed state in Diagnostics.
- Replace the ordinary custom-still path field with a paged picker over indexed
  user and Wallhaven images, retaining a manual-path escape hatch. Eagerly
  prepare automatic video/Workshop representatives in the bounded coordinator
  capture path so adaptive palette previews use the item's pixels without
  applying a wallpaper, palette, or renderer.
- Retain four invisible inert manifest declarations for pre-0.7 global engine
  overrides. Noctalia API 17 cannot delete host-owned plugin settings, so this
  compatibility shim prevents permanent unknown-setting warnings while all
  runtime behavior remains per display.
- Publish provider-install and automatic-representative indexes from the
  coordinator's incremental library scan, cache palette and Workshop lookups,
  and page playlist rows in fixed 12-entry windows so cold or expanded routes
  cannot grow a panel render with the full library or playlist.
- Use fixed 1160 × 780 floating panel geometry to avoid the manager warning
  caused when a saved attached-placement override meets fill sizing. Keep the
  latest validated MotionBGS receipt authoritative until the managed-library
  refresh lands, closing the post-download duplicate-request gap.

## Wall-in-One 0.7.0 - External MotionBGS and runtime stabilization

- Move MotionBGS HTTP, HTML parsing, metadata caching, and downloads out of
  Noctalia's in-process Luau callbacks into the separately installed,
  one-shot `wall-in-one-motionbgs` Python 3.11+ program. Keep
  `motionbgs.luau` as a thin bridge with no update tick or provider parser.
- Detect only the fixed `wall-in-one-motionbgs` command on `PATH`, with an
  advanced absolute-path override. Probe the external program for the schema-1
  search/details/download/clear interface, bound request files to 8 KiB and
  response files to 128 KiB, and degrade only MotionBGS when the program is
  missing or incompatible. Keep independent **Open MotionBGS** and **Get
  helper** links in the panel.
- Preserve the provider boundary's same-origin redirect validation, disabled
  ambient curl configuration, file-size backstop, MIME/signature cross-checks,
  bounded cache, atomic no-replace media installation, and sidecar ownership.
  Bind every RPC to a revocable per-operation guard and end-to-end deadline,
  and reject a final download route whose numeric media ID differs from the
  selected detail record before installation. Reject successful responses with
  missing or contradictory cache/source/time metadata, receipt provenance, or
  clear acknowledgement before publishing them to the coordinator.
  The staged helper currently lives in the repository's top-level
  `motionbgs-helper/` directory and can move to a dedicated repository without
  changing the plugin RPC contract.
- Fix fresh, non-customized Library-card editing by declaring the `panelUi`
  namespace before `openLibraryEntryPairing` closes over it. Add source-order
  and real fresh-Workshop callback coverage for the branch that previously
  resolved `panelUi` as a nil global.
- Bound Wallhaven shop navigation, large-result presentation, and preview
  scheduling so a route click does not concentrate list and thumbnail work in
  one panel callback.
- Page local-library and playlist-library cards in fixed 24-item views and
  playlist navigation in fixed 16-item views. Rebuild drag/drop indexes in
  64-record update slices, preserve the previous complete generation until an
  atomic swap, and include connected displays that do not yet have persisted
  output configuration.
- Validate provider-preview manifests, prune owned files, and remove owned
  orphans in four-entry update slices instead of one initialization callback.
  Keep virtual-library drag tokens separate from persisted-pairing tokens so
  paging and rescans cannot retain stale render-only payloads indefinitely.

## Wall-in-One 0.6.0 - Routed hub and owned renderers

- Replace the attached all-in-one scroll with a full-size floating routed panel:
  Home with one inset route per display; Library with
  Images/Videos/Wallpaper Engine; Shops with
  Wallhaven/MotionBGS/Steam Workshop; per-playlist routes; and Diagnostics.
- Render local libraries and both provider stores as four-column still-led
  browser grids on a 1280-pixel logical panel. Replace unsupported decorative
  box layout and button-variant properties, and split weekday, month, and
  playback controls into bounded rows instead of allowing them to overlap.
- Present image, video, and Workshop inventory as still-led pairing cards with
  selected/automatic representative behavior and an adaptive wallpaper palette
  by default.
- Make indexed media identity authoritative: each file or Workshop scene is an
  implicit pairing, its source is read-only in the item editor, orphan profiles
  cannot reappear as fake Library cards, and public pairing deletion is removed.
- Replace stacked playlist drawers and display selectors with visual draggable
  libraries. Playlist pages accept pairing cards into one reorderable entry
  list; display pages accept playlist cards into a fixed row-1 default followed
  by ordered scheduled overrides, where the lowest matching row wins.
- Make Wall-in-One the direct owner of all dynamic playback through `mpvpaper`
  and `linux-wallpaperengine`. Retire plugin discovery, renderer handoff modes,
  provider control relays, the configurable provider-panel slot, and renderer
  cooperation handshakes.
- Move engine policy into schema-5 per-display state: layer; video enable,
  mute, hardware decode, auto-pause mode and options; and Workshop enable,
  FPS, volume, silent/scaling/clamp behavior, and validated flags. Older
  persisted outputs receive explicit schema-5 defaults without reading removed
  manifest keys.
- Require independent explicit existing image and video roots. Do no scan,
  download, export, capture, managed-directory creation, or provider-cache
  initialization before the matching root is ready. Show the roots, derived
  `Wall-in-One/Wallhaven`, `Wall-in-One/Automatic Stills`, and
  `Wall-in-One/MotionBGS` children, relevant defaults, and private cache paths
  on each medium's Library page.
- Keep the palette service dormant until the explicit image root exists, and
  make provider searches submit immediately on Enter. Fix MotionBGS search
  controls so typed queries do not wait for an unrelated panel refresh before
  becoming actionable.
- Keep MotionBGS at one anchor per callback but use a temporary 16ms parser
  cadence and restore 250ms on every terminal path, reducing a live-like
  206-anchor parse from roughly 52 seconds to roughly 3.3 seconds. Accept only
  an exact same-origin `/search?q=X` → `/tag:<normalized-X>/` canonical redirect
  and apply the same rule to cache validation.

## Wall-in-One 0.5.0 - Provider stores and reusable pairings

- Complete the Wallhaven browser with exact/minimum resolution modes, all
  category/purity masks, Hot/top-list filters, stable random-page seeds, and
  previous/next navigation. Add truthful MotionBGS modes: one unpaged text
  search set, pageable latest/genre/tag/4K catalogs, discoverable genre presets
  with a custom-tag escape hatch, and guarded first-page-only HD
  results while the site's HD page redirect is broken. Parse large listing
  pages across bounded service ticks to respect Noctalia's callback CPU budget.
- Render Wallhaven and MotionBGS result stills through a panel-owned local
  preview cache instead of metadata-only rows. Preview ingress is restricted to
  the providers' validated image origins, capped at 2 MiB per file with four
  workers, and evicted at 64 entries or 64 MiB before local `ui.image` display.
- Remove write-only renderer metadata arrays so every shipped shell helper is
  clean under ShellCheck 0.11.0, and make the offline socket fixture explicit
  when a restricted test sandbox forbids AF_UNIX `bind()`.
- Enforce one-to-one manifest-setting translation coverage, remove the retired
  random-order label, and keep persisted playlist order limited to Rotate or
  Shuffle with Random as an explicit navigation action.
- Refactor late panel presentation/navigation helpers into bounded namespaces
  so the complete hub compiles below Luau's 200-local-register limit; make the
  VM compile, open, render, screenshot, and exercise IPC through the real hub.
- Add bounded exponential restart backoff for an owned renderer that exits
  after its startup probe, with exact acknowledgement/state resolution and a
  stable-run reset instead of an immediate playlist restart loop.
- Keep the last pairing's Noctalia static backing, theme mode, and palette
  selection configured when Wall-in-One stops. The VM now compares all three
  values across disable and verifies bounded palette teardown plus exact-PID
  child cleanup.
- Add a six-page attached-hub router with inset playlist/display routes,
  reusable still/video/Workshop pairing drawers, panel drag/drop with explicit
  button fallbacks, and per-screen default, playback, and calendar controls.
- Add config-schema-4 reusable pairings. Playlist occurrences retain stable
  IDs and safe bundle snapshots, follow catalog edits while linked, and detach
  without data loss when their source catalog card is deleted.
- Replace numeric schedule priority with visible list precedence, add month
  filters and overnight prior-date semantics, and add per-output rotate/shuffle
  and interval overrides with an explicit inherit state.
- Preview built-in, community, and custom palette roles in pairing editors. For
  wallpaper generators, call Noctalia's exact non-applying image palette CLI,
  serialize work, identify sources by SHA-256, reject content changes before
  accepting output, clean owned reload orphans, and keep a bounded cache.
- Keep direct wallhaven.cc and MotionBGS links independent of their optional
  integration paths, so users retain a wallpaper-focused browser fallback.
- Split the coordinator's compact protocol-4 lifecycle snapshot from
  revisioned config, runtime, and library domains. Publish large state only
  when dirty, coalesce panel rendering, and retain a protocol-3 rolling-reload
  fallback instead of repeatedly rebuilding the full hub from one shared key.
- Keep heavy domain publication inside Noctalia's callback budget by trusting
  explicit dirty marks, reusing already-normalized config documents, and using
  native JSON only for exact delta suppression of the small lifecycle object.
- Keep normalized plugin settings on the bounded lifecycle object so a settings
  edit does not republish the unchanged pairing and playlist catalog.
- Make library rescans path-sensitive and defer them out of Noctalia's bounded
  settings callback; provider, playback, palette, and gesture edits no longer
  enumerate unchanged media and Workshop roots.
- Queue live-renderer continuation before observational status publication after
  a paired still is applied, preventing callback-budget pressure from leaving a
  dynamic entry with only its backing image.
- Restore a previously running playlist's exact current entry after service
  restart without consuming rotate history or shuffle state, while preserving
  future due times and schedule precedence.
- Route native Wallhaven and community-palette HTTPS ingress through a bundled
  strict-origin bounded helper with redirects and ambient curl config disabled,
  private header-file credentials, resource/file-size limits, cancellation
  cleanup, response validation, and atomic no-replace installation.
- Disable ambient curl configuration in the bounded MotionBGS helper so its
  explicit same-origin redirect loop remains authoritative, and use bounded
  regular-file reads consistently for transport responses and stored backups.
- Keep managed roots authoritative when image/video roots overlap, require
  exact provider sidecars before exposing deletion, refresh same-path provider
  downloads by completion nonce, and give per-output renderer sockets
  collision-free private names.
- Centralize bounded Workshop-ID validation, separate parameterized IPC-only
  actions from gesture settings, and expose the existing volume step controls
  consistently in the hub and widget action pickers.
- Make VM provider readiness probes one-shot, then use bounded read-only state
  polling with focused fixture/call diagnostics instead of replaying requests
  while a provider is still working.
- Coalesce provider-inventory refresh bursts behind one active probe and one
  boolean follow-up latch, so a hot-swap request is not lost without allowing
  IPC events or subprocesses to accumulate.
- Replace the legacy per-output reel/cycle model with named reusable playlists,
  stable entry IDs, rotate/shuffle order, output-specific Quick Choice parking,
  independent per-output run state, and ordered month/weekday/time schedules.
- Bundle optional dynamic media, selected/automatic still policy, and a complete
  Noctalia theme policy in each playlist entry. New entries created in the
  editor default to adaptive wallpaper colors while preserving an explicit
  **Keep Current** compatibility choice.
- Add bounded built-in, wallpaper-generator, community, and custom palette
  inventory plus missing-selection fallback diagnostics and global
  palette-leader arbitration.
- Add a native Wallhaven official-API browser with optional header-only API-key
  authentication, bounded search/detail, validated managed JPG/PNG download,
  provenance sidecars, and a direct-site fallback.
- Add one shared `bottom` or `background` layer setting for internally owned
  mpvpaper and `linux-wallpaperengine` children, retaining `bottom` as the safe
  default and documenting the compositor-specific niri backdrop use case.
- Capture rendered Workshop PNGs through the exact owned
  `linux-wallpaperengine --screenshot` path with private staging, stable-file
  detection, atomic validation, and source-video/preview fallback. Preserve the
  legacy 1–120-frame setting while clamping the owned capture command
  to linux-wallpaperengine's five-frame maximum.
- Serialize native capture with existing per-output ownership, restore only a
  still-current displaced child, and reject stale callbacks after stop, hotplug,
  backend change, reload, or disable without signalling a foreign renderer.
- Allow internally owned mpvpaper and Wallpaper Engine children to coexist on
  different outputs, with exact-PID break-before-make replacement on one output
  and explicit process ownership boundaries.
- Add capability-driven playback IPC. mpvpaper uses a private socket for
  pause/resume/toggle, mute/unmute, and volume; Wallpaper Engine exposes only
  its supported signal controls. Commands are one-shot and idle heartbeats do
  not publish unchanged state.
- Add user-selected image/video roots, shared-root media classification, marked
  managed MotionBGS and Automatic Stills children, sidecar-gated deletion, and
  automatic cleanup of only the managed still belonging to an explicitly
  deleted managed video. Add a marked native Wallhaven child while keeping every
  file without Wall-in-One provenance outside its delete authority.
- Enable automatic still creation/pairing by default, keep manual exports in
  the user image root, make configured-manual pairing an immediate standalone
  backing action, and add Steam launch plus Workshop links.
- Carry the exact active Workshop ID and selected layer in renderer status and
  migrate config/runtime storage to schema 4/6 with stable pairing/playlist state, a
  bounded per-output `current_workshops` map, and recoverable two-document
  migration from config schema 1/2/3 and runtime schema 1–5.

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
- Add an early provider-control experiment, superseded by the directly owned
  renderer and native shop services in 0.6.0.
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

- Prototype provider policy and backing export. The delegation model from this
  release was retired by Wall-in-One 0.6.0's native shops and owned renderers.

## Wall-in-One 0.2.0 - Live/static coordination preview

- Rename the early wallpaper hub and its plugin, widget, panel, service, and
  Control Center IDs to `goober/wall-in-one`.
- Prototype live/static coordination and full-resolution still export from
  configured video or Workshop sources.
- Pair an exported still through `setWallpaper` so Noctalia persists a real
  image for its backdrop, hooks, lock-screen fallback, and wallpaper-derived
  colors while the dynamic provider remains active.
- Add selectable color-scheme synchronization and an optional palette-output
  leader for Noctalia's single global palette. Preserve explicit lock-screen
  wallpaper overrides instead of rewriting them.
- Establish the initial safe video/preview fallback later replaced by owned
  rendered capture.

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
