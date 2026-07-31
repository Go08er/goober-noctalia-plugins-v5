# Hydra Update Examiner

Public-test candidate for the Noctalia v5 port of the Hydra Update Examiner bar
widget. It estimates how close a NixOS or Nixpkgs channel is to publishing its
next update.

![Hydra Update Examiner staging thumbnail](thumbnail.webp)

> This is a v5 beta staging build. The thumbnail comes from the v4 widget and
> should be replaced after an interactive native v5 capture using the intended
> production theme and layout.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goober/hydra-update-examiner` |
| Entries | Bar widget: `hydra`; service: `status` |

The singleton service polls Hydra once for all widget placements; each widget
renders that shared result with its own display settings.

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
- Right click: open the current Hydra jobset page with `xdg-open`.
- Middle click: use Noctalia's built-in widget binding to open settings.

User-configured Noctalia widget bindings can override these plugin click
callbacks.

The singleton service can also be driven directly:

```bash
noctalia msg plugin goober/hydra-update-examiner:status all refresh
noctalia msg plugin goober/hydra-update-examiner:status all force-refresh
noctalia msg plugin goober/hydra-update-examiner:status all open
```

## Settings

Plugin-wide data settings are shared by the service and every widget placement:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `channel_preset` | `select` | `nixos-unstable` | Selects a supported NixOS or Nixpkgs channel, or exposes `custom_channel`. |
| `custom_channel` | `string` | empty | Exact supported channel name used only when `channel_preset` is `custom`; this is not an arbitrary Hydra URL. |
| `refresh_interval_minutes` | `int` | `60` | Poll interval in minutes, from 1 through 1440. |
| `close_threshold` | `int` | `90` | Readiness percentage, from 1 through 100, at which the close state begins. |

Per-widget presentation settings apply independently to each bar placement:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `display_mode` | `select` | `always` | Shows readiness text continuously; `icon_only` hides it. |
| `running_color` | `color` | `secondary` | Color used during normal progress. |
| `stalled_color` | `color` | `error` | Color used for blocked or error states. |
| `close_color` | `color` | `tertiary` | Color used at or above `close_threshold`. |
| `launched_color` | `color` | `primary` | Color used when the candidate revision is published. |
| `running_glyph` | `glyph` | `server-bolt` | Glyph used during normal progress. |
| `stalled_glyph` | `glyph` | `server-off` | Glyph used for blocked or error states. |
| `close_glyph` | `glyph` | `server-spark` | Glyph used near readiness. |
| `launched_glyph` | `glyph` | `rocket` | Glyph used after publication. |

The v4 hover-only percentage mode is not included because v5 has no documented
equivalent yet.

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

The current test target is Noctalia `v5.0.0-beta.7`. The manifest intentionally
keeps plugin API level 3, the oldest level containing every capability the port
uses; the beta.7 host supports cumulative API levels through 20. The initial
port also needs these commands on `PATH`:

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

The initial v5 port was prepared with OpenAI Codex assistance. It is available
as a standalone custom Git source and has not been submitted to an upstream
Noctalia catalog. The native beta.7/API 3 VM integration test passed on
2026-07-31; interactive UI coverage remains before a stable release.

## License

MIT. See `LICENSE`.
