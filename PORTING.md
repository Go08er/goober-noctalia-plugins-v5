# Noctalia v5 porting notes

Specification snapshot: 2026-07-31. Noctalia `v4.7.7` is the final
Quickshell-based v4 release, and `v5.0.0-beta.7` is the current native v5 beta.
The `noctalia_4.7` directory name labels the preserved v4 generation; its
unchanged manifest still declares its original minimum Noctalia version.

## Current boundary

Noctalia v5 is a native shell and plugin host. The old QML entry points cannot
be upgraded in place because v5 plugins use a TOML manifest and isolated Luau
entry scripts. The v4.7 source remains unchanged in `../noctalia_4.7` as the
behavioral reference.

The v5 repository is also a directly importable custom Git source. Its root
`catalog.toml` replaces v4's `registry.json`, and Noctalia materializes the
plugin from the `hydra-update-examiner/` directory after users add
<https://github.com/Go08er/goober-noctalia-plugins-v5> as a Git source. This is
independent of upstream catalog inclusion: the repository has not been
submitted to or accepted into Noctalia's official or community catalogs.

This public-test port deliberately keeps the proven Bash/Hydra backend for its
first milestone while replacing every Quickshell-facing layer:

| v4.7 | v5 staging |
| --- | --- |
| `manifest.json` | `plugin.toml` and root `catalog.toml` |
| `Main.qml` | `service.luau` |
| `BarWidget.qml` | `widget.luau` |
| `NPopupContextMenu` | attached `panel.luau` entry |
| `Settings.qml` and JSON defaults | typed manifest settings |
| `i18n/en.json` | `translations/en.json` |
| `pluginApi.mainInstance` | `noctalia.state` |
| QML `Process` and `Timer` | `noctalia.runAsync` and service updates |

## API compatibility through beta.7

The v5 manifest compatibility gate changed after the first staging pass.
`min_noctalia` is no longer the manifest/catalog gate; both now require a
positive integer `plugin_api`. The first public-test port intentionally declared
API level 3. Customization parity now targets API level 15 because the
right-click surface declares an overridable widget action (API 14) and opens
the plugin's own settings page through `noctalia.openSettings()` (API 15).
Noctalia v5.0.0-beta.7 supports cumulative plugin API levels through 20. Hover
events themselves are available at API 3 and did not require this bump.

Beta.3 also rejected literal setting labels in favor of translated `label_key`
and option `label_key` fields. Current community validation additionally
requires translation catalogs to use nested objects with lowercase key
segments. The source and local validator follow those rules along with
lowercase plugin IDs, the published tag vocabulary, thumbnail constraints, and
the 120-character catalog-description limit.

## Beta.3 test result

The tagged v5.0.0-beta.3 host was built locally without installing it. Its
first-party offline plugin linter accepted this source with zero errors and zero
warnings, and its config validator accepted the documented path source and
widget placement.

A short live Wayland run used temporary config, state, and data roots under
`/tmp`. Noctalia loaded both entries, started the `status` service, instantiated
the `hydra` widget on a temporary bar, watched both Luau files, and shut down
without a plugin or script error. D-Bus was disabled for the final run so the
test could not control Bluetooth, notifications, or other session services.
Separately, the helper returned valid live Hydra JSON for `nixos-unstable` with
state `launched` and matching evaluation/channel revisions.

That initial probe was the last v5 host-session test. Ongoing integration now
uses the repository's disposable NixOS VM test. The harness is pinned to the
exact beta.7 host under headless Sway with software rendering, a private session
bus, guest-only state, and deterministic Hydra fixtures. Host Noctalia
configuration and processes are outside the test boundary.

The earlier beta.3/API 3 baseline passed on 2026-07-18, and the initial
beta.7/API 3 automated run passed on 2026-07-31. The current beta.7/API 15 run
also passed on 2026-07-31. In addition to the native linter and config
validator, it verified layer-shell support, Git-source discovery and
materialization, two widget placements using shared and overridden
presentation, service/widget IPC, the `Launched` Hydra fixture, hover rendering
through the production callback, the attached action panel, documentation and
scoped-settings actions, service/widget/panel hot reload, guest screenshots,
and clean shutdown. The v0.3.0 harness also opens the widget editor with local
glyphs enabled, keyboard-activates the first selector, and captures Noctalia's
native searchable **Pick a Glyph** menu. No plugin/Luau error marker appeared
in the recorded run.

## Refinements already included

- One headless service owns polling, so multiple bar placements do not start
  duplicate Hydra requests.
- Refreshes are single-flight and manual requests have a short cooldown.
- All v4-style data and appearance values remain available as plugin-wide
  defaults. Each placement independently chooses whether to inherit shared text
  and colors or shared glyph names.
- Per-widget glyphs are the v0.3.0 default because widget-scoped `glyph` settings
  receive Noctalia's native searchable picker. Middle-click opens the placement
  settings, where the selector button sits beside each glyph field.
- Hover-only readiness text uses the native bar-widget pointer callback.
- Right click opens an attached native action panel with refresh, Hydra,
  settings, and documentation actions; middle click retains the normal widget
  editor binding.
- The service and widget exchange a small presentation-neutral status object.
- Failed refreshes retain the last good result and mark it stale.
- Process-lifetime status is protocol- and config-keyed, and a service-ready
  handshake prevents clicks from being lost during entry reloads.
- Shell arguments are single-quoted before crossing the Luau-to-shell boundary.
- The helper now emits an explicit state alongside its backward-compatible
  text, tooltip, color, and URL fields.
- The source has local validation and a repository validation workflow.
- The source can be installed directly from GitHub through Noctalia's Settings
  interface, plugin-source IPC, or declarative v5 configuration.
- A reproducible VM harness exercises Git-source cloning and materialization,
  the native host, independent text/color and glyph scopes, hover rendering,
  the attached panel, actions, IPC, hot reload, the widget settings surface,
  the opened native glyph menu, and headless-output captures without sharing
  the host desktop.

### V0.2.0 to v0.3.0 settings change

V0.2.0 used `use_shared_presentation` for readiness text, colors, and glyphs as
one unit. V0.3.0 leaves that setting responsible for text and colors only and
adds `use_shared_glyphs`, defaulting to `false`. Existing placements therefore
use their widget glyph values and expose Noctalia's adjacent native picker by
default. Set `use_shared_glyphs = true` on a placement to retain v0.2.0's shared
glyph behavior.

## Known gaps

- The backend still depends on Bash plus command-line HTTP/JSON/text tools.
- The helper still scrapes Hydra HTML for grouped evaluation counts.
- There is no persistent cache or cross-process file lock yet.
- Backend tooltip text is English-only.
- There is no generic plugin context-menu primitive, so the v4 menu is expressed
  as a native attached panel rather than a compositor popup menu.
- Current Noctalia v5 renders root/plugin-wide `glyph` settings as text inputs,
  not its searchable picker. The shared names remain an optional shared set;
  widget glyphs default to local scope so users get the native selector.
- V4 settings are not imported automatically because the plugin ID, key names,
  and settings store changed; the README provides a direct mapping.
- The inherited thumbnail is a v4 screenshot and should be replaced after an
  interactive native v5 capture with the intended production theme/layout.
- Noctalia v5 is beta; beta.7 supports plugin API levels through 20 while this
  port targets API 15, so each beta still needs a compatibility check.

## Next milestones

1. Use the interactive VM driver to cover physical pointer dispatch,
   action-panel button activation, selecting and applying a different glyph,
   settings edits, manifest reload, and stale/error presentation, then capture
   a native replacement screenshot. Automated keyboard activation of the glyph
   menu, entry dispatch, rendering, actions, and Luau hot reload are covered.
2. Add recorded Hydra response fixtures for running, blocked, launched, paused,
   malformed, and transport-failure cases.
3. Move request orchestration to `noctalia.http` or a small compiled helper,
   retaining HTML only where Hydra exposes no equivalent JSON summary.
4. Add an XDG cache with freshness metadata and explicit `paused`,
   `published-paused`, `stale`, and `error` states.
5. Reduce the active-candidate request budget and measure response sizes before
   relying on large evaluation build lists.
6. Re-check the community plugin review requirements before any future
   submission. Direct installation as a custom Git source is not an upstream
   catalog submission or acceptance.

## Specification references

- <https://docs.noctalia.dev/v5/plugins/>
- <https://docs.noctalia.dev/v5/plugins/development/>
- <https://docs.noctalia.dev/v5/plugins/development/manifest/>
- <https://docs.noctalia.dev/v5/plugins/development/entries/>
- <https://docs.noctalia.dev/v5/plugins/development/plugin-api/>
- <https://docs.noctalia.dev/v5/plugins/development/runtime-api/>
- <https://docs.noctalia.dev/v5/plugins/development/workflow/>
- <https://github.com/noctalia-dev/official-plugins>
- <https://github.com/noctalia-dev/community-plugins>
