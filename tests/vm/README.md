# Noctalia v5 VM tests

These tests boot disposable NixOS QEMU guests against pinned Noctalia tag
`v5.1.0`. They never launch
Noctalia in the host Wayland session or read or write the host Noctalia
configuration.

Run one automated suite from the repository root:

```bash
nix build -L path:.#vm-test
nix build -L path:.#vm-test-theme
```

Use the explicit `path:.` source while developing: Git-backed flake evaluation
omits untracked files, which can make a new manifest entry appear to be missing
inside the guest. Once every file is committed, `.#...` is equivalent.

| Package | Coverage |
| --- | --- |
| `vm-test` | Hydra rendering, actions, hot reload, settings, and native searchable glyph picker |
| `vm-test-theme` | Live built-in scheme and dark/light transitions in both widgets and their already-open panels |

Each suite also exposes an interactive driver by adding `-driver` to its
package name. For example:

```bash
nix build -L path:.#vm-test-driver
./result/bin/nixos-test-driver
```

The guests use headless Sway because Noctalia's bar needs a real Wayland
compositor with `zwlr_layer_shell_v1`, an output, and EGL/GLES2. Rendering uses
Mesa software paths; no host desktop or GPU session is shared.

The automated path is offline and deterministic. Each guest commits its staged
catalog source into a local Git repository and adds that `file://` source using
the same `plugins source add ... git ...` IPC used for GitHub. This exercises
catalog discovery, lazy clone, and managed plugin materialization without
network access. Provider and external-command behavior comes from bounded guest
fixtures.

## Hydra Update Examiner

The Hydra suite covers the pinned host's native lint and config
validation; two independent widget presentations; native action defaults;
service, widget, and panel IPC; hover rendering; all three hot-reload paths;
correctly scoped polling and appearance settings; the response helper;
screenshots; keyboard opening of Noctalia's native searchable glyph menu;
and rendered matching/no-match search results. Noctalia 5.1 hosts the picker
inside Settings, so the test does not depend on the former popup-size log.

In this headless fixture, the pinned 5.1 host's initial unfiltered glyph grid
appears blank; typing a search renders matching icons. The initial screenshot
is retained for review. Passing search checks does not certify unfiltered
browsing or resolve that host rendering issue; check it on a real desktop
before recommending a shell upgrade.

The headless compositor has no physical pointer, so the hover probe calls the
production `onHover(true)` callback through a temporary guest-only hot reload.
Physical pointer dispatch, choosing and applying a different glyph, live GitHub
network cloning, and the remaining Hydra response states remain exploratory
coverage.

## Live theme transitions

The theme suite runs both production plugins with fixed, offline provider
fixtures. Each real attached panel stays open while the shell changes from
Noctalia dark to Dracula dark, Noctalia light, and back to Noctalia dark. At every
step the test checks foreground pixels against the pinned host's current
primary color in both widgets and the open panel. It also verifies that
the active panel remains the same and no plugin hot reload occurs. The resulting
screenshots are retained in the test output.

The pinned host CLI can return exit code 0 with an empty acknowledgment when
its two-second response read times out. The theme test never replays a setting
or panel command: one read-only state query must confirm its outcome, or the
test fails. Any such reconciliation is recorded in `ipc-reconciliation.json`
alongside the screenshots; explicit errors are never accepted.

This covers theme-role colors under built-in schemes and light/dark mode; it
does not require custom literal colors to change or exercise wallpaper-generated
and community palettes. All IPC, fake command processes, and screenshots remain
inside the disposable guest.

All suites treat Luau runtime errors, undeclared settings, failed hot reloads,
and missing glyph warnings as failures. Run the relevant target after any
plugin or harness change; a prior result does not certify the current tree.
