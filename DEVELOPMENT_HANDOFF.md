# Development handoff — 2026-08-01

This branch is a resumable Noctalia v5 development snapshot, not a release.

## Repository state

- Branch: `agent/wall-in-one-v0.4`
- Base/remote: `b547583` (`origin/main` at resume time)
- Scope: Wall-in-One 0.4 only. The HUE/NocVox settings work is already part of
  `main` and is not carried as a separate change here.
- Nothing on this branch has been pushed, merged, tagged, released, or otherwise
  published.

## Implemented production scope

### Wall-in-One 0.4

- Noctalia static wallpaper/palette coordination and official Wallhaven panel
  integration.
- Optional, bounded MotionBGS public-page search/detail/download adapter with
  same-origin validation, atomic MP4 install, provenance sidecar, cancellation
  barriers, bounded caches, and a permanent direct-site fallback.
- Internally owned `mpvpaper` and `linux-wallpaperengine` playback through an
  exact-PID supervisor; external plugins remain provider-owned.
- Auto/external/internal backend policy that fails closed until enabled-plugin
  ownership is known and never treats probe failure as external-owner absence.
- Persistent static↔video/Workshop pairs, including explicit selected-still
  binding, durable GIF→PNG extraction, capture fingerprints, and color sync.
- Persistent per-output mixed scheduler with sequential/shuffle/random order,
  interval controls, pause/resume/stop, start-on-load opt-in, generation
  barriers, hotplug protection, and exact renderer acknowledgements.
- Incremental, bounded metadata processing for local videos and Steam Workshop
  projects. The Noctalia `listDir()` call still materializes a directory before
  the plugin processes at most 1,024 names in four-item service batches.
- Runtime/config documents capped at 8 MiB with bounded nested normalization,
  registry pruning, atomic writes/backups, and fail-closed diagnostics.

## Validation completed tonight

- Noctalia v5 lint: Wall-in-One clean.
- Repository validator clean.
- Bash syntax clean for all Wall-in-One helpers. ShellCheck was unavailable in
  the base shell used for the latest validator pass.
- MotionBGS helper self-test clean.
- Wall-in-One offline contract clean after the final production freeze.
- Nix VM expression parses cleanly.
- A full corrected Nix VM pass exercised and passed startup cleanup, bounded library
  processing, exact renderer argv/PID ownership, static→video→Workshop
  scheduling, pause/rejected-navigation/resume, backend handoff/conflict
  recovery, explicit still binding, capture currentness, and persistence.

## Intentionally unfinished

The full baseline VM now passes. The next renderer slice should add native
`linux-wallpaperengine --screenshot` capture, make the layer configurable, and
persist the internally selected Workshop ID. Follow that with persistent
per-output backing selection and source-aware capture fingerprints.

Real compositor rendering remains a manual boundary. Validate both internal
renderers, Wallpaper Engine screenshots, lock-screen fallback, palette changes,
and output hotplug in the user's Noctalia v5 desktop session.

## Resume checklist

From the repository root:

```bash
noctalia plugins lint wall-in-one
python3 tools/validate.py
python3 wall-in-one/tests/test_contract.py
nix build -L path:.#vm-test-wall-in-one --out-link result-wallpaper
```

Then follow `tests/manual/wall-in-one.md`. Inspect the full diff before any push,
PR, merge, tag, release, or publication.
