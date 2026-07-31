# Changelog

All notable staging changes will be recorded here.

## 0.1.0 - Public test candidate

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
