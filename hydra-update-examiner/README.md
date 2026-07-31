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

The singleton service polls Hydra once for all widget placements; each widget
renders that shared result with plugin-wide appearance defaults or its own
per-placement overrides.

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

[plugin_settings."goober/hydra-update-examiner"]
shared_display_mode = "on_hover"
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
- Right click: open the native actions panel, with Refresh, Open Hydra, Plugin
  settings, and Documentation commands.
- Middle click: use Noctalia's built-in binding to open this placement's widget
  settings.

User-configured Noctalia widget bindings can override these plugin click
callbacks.

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

Open the plugin's gear under **Settings** → **Plugins** to edit all 13 v4-style
shared controls in one place. The first four configure the shared polling
service:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `channel_preset` | `select` | `nixos-unstable` | Selects a supported NixOS or Nixpkgs channel, or exposes `custom_channel`. |
| `custom_channel` | `string` | empty | Exact supported channel name used only when `channel_preset` is `custom`; this is not an arbitrary Hydra URL. |
| `refresh_interval_minutes` | `int` | `60` | Poll interval in minutes, from 1 through 1440. |
| `close_threshold` | `int` | `90` | Readiness percentage, from 1 through 100, at which the close state begins. |

The remaining nine are shared appearance defaults:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `shared_display_mode` | `select` | `always` | `on_hover`, `always`, or `icon_only` readiness text. |
| `shared_running_color` | `color` | `secondary` | Color used during normal progress. |
| `shared_stalled_color` | `color` | `error` | Color used for blocked, stale, or error states. |
| `shared_close_color` | `color` | `tertiary` | Color used at or above `close_threshold`. |
| `shared_launched_color` | `color` | `primary` | Color used when the candidate revision is published. |
| `shared_running_glyph` | `glyph` | `server-bolt` | Glyph used during normal progress. |
| `shared_stalled_glyph` | `glyph` | `server-off` | Glyph used for blocked, stale, or error states. |
| `shared_close_glyph` | `glyph` | `server-spark` | Glyph used near readiness. |
| `shared_launched_glyph` | `glyph` | `rocket` | Glyph used after publication. |

Every placement uses those values by default. Middle-click the bar widget, or
open its gear under **Settings** → **Bar**, to opt a placement out and reveal
its override controls. None of these core appearance settings require the
global **Show Advanced** toggle:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `use_shared_presentation` | `bool` | `true` | Uses the plugin-wide appearance defaults; turn off to reveal this placement's overrides. |
| `display_mode` | `select` | `always` | Override with `on_hover`, `always`, or `icon_only`. |
| `running_color` | `color` | `secondary` | Normal-progress color override. |
| `stalled_color` | `color` | `error` | Blocked, stale, or error color override. |
| `close_color` | `color` | `tertiary` | Color used at or above `close_threshold`. |
| `launched_color` | `color` | `primary` | Color used when the candidate revision is published. |
| `running_glyph` | `glyph` | `server-bolt` | Normal-progress glyph override. |
| `stalled_glyph` | `glyph` | `server-off` | Blocked, stale, or error glyph override. |
| `close_glyph` | `glyph` | `server-spark` | Near-readiness glyph override. |
| `launched_glyph` | `glyph` | `rocket` | Publication glyph override. |

Noctalia sends pointer enter/leave events to the widget, so `on_hover` behaves
like v4: the glyph remains visible and the readiness text expands only while
the pointer is over the widget.

### Migrating v4 appearance

Noctalia cannot import the old values automatically because v4 used a different
plugin ID, settings store, and camelCase key names. Re-enter them in the plugin
gear using this mapping:

| v4 key | v5 shared key |
| --- | --- |
| `percentDisplayMode` | `shared_display_mode` (`onhover` → `on_hover`, `alwaysShow` → `always`, `alwaysHide` → `icon_only`) |
| `runningColor` | `shared_running_color` |
| `stalledColor` | `shared_stalled_color` |
| `closeColor` | `shared_close_color` |
| `launchedColor` | `shared_launched_color` |
| `runningIcon` | `shared_running_glyph` |
| `stalledIcon` | `shared_stalled_glyph` |
| `closeIcon` | `shared_close_glyph` |
| `launchedIcon` | `shared_launched_glyph` |

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
2026-07-31, including both presentation scopes, hover rendering, the attached
panel, its documentation and scoped-settings actions, hot reload, and clean
shutdown.

## License

MIT. See `LICENSE`.
