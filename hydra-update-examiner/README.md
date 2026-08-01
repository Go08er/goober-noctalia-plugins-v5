# Hydra Update Examiner

Native Noctalia v5 port of the Hydra Update Examiner bar widget. It estimates
how close a NixOS or Nixpkgs channel is to publishing its next update.

![Hydra Update Examiner staging thumbnail](thumbnail.webp)

> This is a v5 beta staging build. The thumbnail comes from the v4 widget and
> should be replaced after an interactive native v5 capture using the intended
> production theme and layout.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goober/hydra-update-examiner` |
| Entries | Bar widget: `hydra`; actions panel: `actions`; service: `status` |

The singleton service polls Hydra once for all widget placements. Channel,
refresh, and threshold controls are plugin-wide; text, colors, glyphs, and
gesture bindings belong to each bar placement.

## What it does

The plugin checks public NixOS channel and Hydra endpoints. It displays a
readiness score in the bar and switches to `Launched` when the latest visible
evaluation revision matches the published channel revision.

The score combines:

- Candidate evaluation progress.
- Channel-gate status, such as `tested` or `unstable`.
- Failed and pending gate constituent builds.
- The published revision from `channels.nixos.org`.

This is a heuristic. Hydra does not publish a single authoritative estimate of
when a channel will advance.

## v5 architecture

- `service.luau` is a singleton that schedules refreshes and publishes status.
- `widget.luau` is a thin bar client watching the shared status channel.
- `panel.luau` is the native attached action surface opened by right click.
- `plugin.toml` generates native settings UI; there is no QML settings page.
- `scripts/hydra-channel-progress` is the retained v4 backend for this first
  port milestone.

One service feeds every widget placement, avoiding duplicate requests when the
widget appears on multiple bars or monitors. Failed refreshes keep the last
successful result visible and mark it stale.

## Usage

Add the published repository as a custom Noctalia v5 Git source, then enable
the plugin:

```bash
noctalia msg plugins source add goober-v5 git https://github.com/Go08er/goober-noctalia-plugins-v5
noctalia msg plugins enable goober/hydra-update-examiner
noctalia msg plugins list
```

Then add `goober/hydra-update-examiner:hydra` through the bar widget picker.
The equivalent graphical flow is **Settings** → **Plugins** → add source:
choose **Git**, name it `goober-v5`, enter
<https://github.com/Go08er/goober-noctalia-plugins-v5>, and enable
`goober/hydra-update-examiner` after the source loads.

For a declarative configuration, the relevant shape is:

```toml
[plugins]
enabled = ["goober/hydra-update-examiner"]
auto_update = true

[[plugins.source]]
name = "goober-v5"
kind = "git"
location = "https://github.com/Go08er/goober-noctalia-plugins-v5"
enabled = true

[widget.hydra-readiness]
type = "goober/hydra-update-examiner:hydra"
display_mode = "on_hover"
running_glyph = "server-bolt"

[plugin_settings."goober/hydra-update-examiner"]
refresh_interval_minutes = 60
```

Add `hydra-readiness` to the desired bar section using your existing bar
configuration. Retain any other `[[plugins.source]]` entries you use when
managing the configuration declaratively.

Refresh the Git source with the Settings source refresh control or:

```bash
noctalia msg plugins update goober-v5
```

To remove it:

```bash
noctalia msg plugins disable goober/hydra-update-examiner
noctalia msg plugins source remove goober-v5
```

For development, clone the repository and use its root as a path source instead:

```bash
noctalia msg plugins source add goober-v5-dev path /absolute/path/to/goober-noctalia-plugins-v5
noctalia msg plugins enable goober/hydra-update-examiner
```

Do not use `hydra-update-examiner/` itself as the path source: Noctalia expects
the source root containing `catalog.toml`.

## Controls and IPC

- Left click: refresh, subject to a 30-second cooldown.
- Right click: open the native actions panel, with Refresh, Open Hydra, Polling
  settings, and Documentation commands.
- Middle click: use Noctalia's built-in binding to open this placement's widget
  settings.

Left and right are native plugin action defaults, while middle is Noctalia's
host default. All three are visible and independently overridable in this
placement's **Actions** section.

The singleton service can also be driven directly:

```bash
noctalia msg plugin goober/hydra-update-examiner:status all refresh
noctalia msg plugin goober/hydra-update-examiner:status all force-refresh
noctalia msg plugin goober/hydra-update-examiner:status all open
```

The actions panel is also addressable for testing or automation:

```bash
noctalia msg panel-toggle goober/hydra-update-examiner:actions
noctalia msg plugin goober/hydra-update-examiner:actions all documentation
```

## Settings

Hydra follows Noctalia v5's two settings scopes instead of duplicating the same
controls in both menus.

Open the plugin's gear under **Settings** → **Plugins**, or choose **Polling
settings** in the right-click panel, for the four values owned by the singleton
service:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `channel_preset` | `select` | `nixos-unstable` | Selects a supported NixOS or Nixpkgs channel, or exposes `custom_channel`. |
| `custom_channel` | `string` | empty | Exact supported channel name used only when `channel_preset` is `custom`; this is not an arbitrary Hydra URL. |
| `refresh_interval_minutes` | `int` | `60` | Poll interval in minutes, from 1 through 1440. |
| `close_threshold` | `int` | `90` | Readiness percentage, from 1 through 100, at which the close state begins. |

### Widget appearance and glyph picker

Middle-click a Hydra widget to open that placement's settings. If its normal
middle-click binding was changed, open the widget's gear under **Settings** →
**Bar**. All presentation controls are together there:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `display_mode` | `select` | `always` | `on_hover`, `always`, or `icon_only` readiness text for this placement. |
| `running_color` | `color` | `secondary` | Normal-progress color for this placement. |
| `stalled_color` | `color` | `error` | Blocked, stale, or error color for this placement. |
| `close_color` | `color` | `tertiary` | Near-readiness color for this placement. |
| `launched_color` | `color` | `primary` | Publication color for this placement. |
| `running_glyph` | `glyph` | `server-bolt` | Normal-progress glyph selected with the adjacent picker button. |
| `stalled_glyph` | `glyph` | `server-off` | Blocked, stale, or error glyph selected with the adjacent picker button. |
| `close_glyph` | `glyph` | `server-spark` | Near-readiness glyph selected with the adjacent picker button. |
| `launched_glyph` | `glyph` | `rocket` | Publication glyph selected with the adjacent picker button. |

Press the button adjacent to a glyph field to open Noctalia's searchable
**Pick a Glyph** menu. The picker is not arbitrarily restricted by Hydra:
Noctalia v5 currently attaches it to widget-scoped glyph controls, while a
root plugin `glyph` setting renders as a text field. Keeping glyphs here gives
the complete native picker and lets two Hydra placements deliberately look
different.

Click, scroll, and thumb-button bindings are also per placement in the same
widget editor. This is the v5 convention: service configuration is shared by
the plugin, while presentation and gestures describe a particular bar widget.

Noctalia sends pointer enter/leave events to the widget, so `on_hover` behaves
like v4: the glyph remains visible and the readiness text expands only while
the pointer is over the widget.

### Migrating v4 appearance

Noctalia cannot import the old values automatically because v4 used a different
plugin ID, settings store, and camelCase key names. Re-enter appearance values
in each widget's settings using this mapping:

| v4 key | v5 target |
| --- | --- |
| `percentDisplayMode` | Widget `display_mode` (`onhover` → `on_hover`, `alwaysShow` → `always`, `alwaysHide` → `icon_only`) |
| `runningColor` | Widget `running_color` |
| `stalledColor` | Widget `stalled_color` |
| `closeColor` | Widget `close_color` |
| `launchedColor` | Widget `launched_color` |
| `runningIcon` | Widget `running_glyph`, selected with the native picker |
| `stalledIcon` | Widget `stalled_glyph`, selected with the native picker |
| `closeIcon` | Widget `close_glyph`, selected with the native picker |
| `launchedIcon` | Widget `launched_glyph`, selected with the native picker |

V0.4.0 removes the temporary `shared_*` appearance settings and the two
inheritance switches from v0.2/v0.3. Existing local `display_mode`, color, and
glyph values remain the active widget settings; obsolete shared keys can be
deleted from handwritten configuration.

## Supported channels

| Channel | Hydra jobset | Gate job |
| --- | --- | --- |
| `nixos-unstable` | `nixos:unstable` | `tested` |
| `nixos-unstable-small` | `nixos:unstable-small` | `tested` |
| `nixos-stable` | Current supported `nixos-YY.MM` | `tested` |
| `nixos-stable-small` | Current supported `nixos-YY.MM-small` | `tested` |
| `nixos-YY.MM` | `nixos:release-YY.MM` | `tested` |
| `nixos-YY.MM-small` | `nixos:release-YY.MM-small` | `tested` |
| `nixpkgs-unstable` | `nixpkgs:unstable` | `unstable` |

The exact-channel field is not a generic third-party Hydra URL. It accepts only
the public NixOS/Nixpkgs channels mapped by the backend.

## Requirements

The current test target is Noctalia `v5.0.0-beta.7`. The manifest targets plugin
API level 15: API 14 provides overridable widget gesture defaults, and API 15
provides the scoped plugin-settings action used by the attached panel. The
beta.7 host supports cumulative API levels through 20. The port also needs
these commands on `PATH`:

- `bash`
- `curl`
- `jq`
- `perl`
- `grep`
- `awk`
- `sed`
- `head`
- `tr`
- `cut`
- `date`
- `cat`
- `timeout`
- `xdg-open` for the right-click action

On typical Linux systems, `head`, `tr`, `cut`, `date`, and `cat` are supplied
by GNU coreutils.

On NixOS, a minimal explicit addition for commonly missing tools is:

```nix
environment.systemPackages = with pkgs; [
  curl
  jq
  xdg-utils
];
```

The helper can be checked independently:

```bash
./scripts/hydra-channel-progress --channel nixos-unstable
```

## Network behavior and limitations

The backend makes read-only public requests to `channels.nixos.org`,
`nix-channels.s3.amazonaws.com` for stable alias discovery, and
`hydra.nixos.org`. It uses Hydra JSON where practical and still reads Hydra HTML
for grouped evaluation counts. Public services receive normal connection
metadata such as IP address and user agent.

There is a single in-process polling service and a click cooldown, but no
persistent cache or cross-process lock yet. The backend has a 55-second overall
deadline. Temporary Hydra outages can therefore produce a stale or error state.

## Development note

The v5 port was prepared with OpenAI Codex assistance. It is available as a
standalone custom Git source and has not been submitted to an upstream
Noctalia catalog. The native beta.7/API 15 integration gate passed on
2026-07-31, including shared and local presentation, hover rendering, the
attached panel, its documentation and scoped-settings actions, hot reload, and
clean shutdown. The v0.3.0 harness additionally captures the widget settings
surface and opens Noctalia's native searchable **Pick a Glyph** menu. V0.4.0
streamlines the settings scopes without changing the polling protocol.

## License

MIT. See `LICENSE`.
