#!/usr/bin/env python3
"""Pin the Wallpaper Director Hub's phase-one safety contract."""

from __future__ import annotations

import json
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    manifest = tomllib.loads((ROOT / "plugin.toml").read_text())
    assert manifest["id"] == "goober/wallpaper-director"
    assert manifest["version"] == "0.1.0"
    assert manifest["plugin_api"] == 17
    assert [entry["id"] for entry in manifest["service"]] == ["hub"]
    assert [entry["id"] for entry in manifest["widget"]] == ["wallpapers"]
    assert [entry["id"] for entry in manifest["panel"]] == ["director"]
    assert [entry["id"] for entry in manifest["shortcut"]] == ["wallpapers-shortcut"]
    assert manifest["widget"][0]["actions"]["middle"] == "none"

    translations = json.loads((ROOT / "translations" / "en.json").read_text())
    assert translations["plugin"]["title"] == "Wallpaper Director"
    readme = (ROOT / "README.md").read_text()
    assert "noctalia msg panel-toggle goober/wallpaper-director:director" in readme
    assert "Open Wallpaper Director" in readme

    service = (ROOT / "service.luau").read_text()
    for action in (
        'left = "native_open"',
        'middle = "wallhaven_open"',
        'right = "w_engine_open"',
    ):
        assert action in service
    for public_contract in (
        '"noctalia/wallhaven:browser"',
        '"tadomika_ari/w-engine:w-engine-panel"',
        'native_next = "wallpaper-next"',
        'native_previous = "wallpaper-previous"',
        'native_random = "wallpaper-random"',
        '"noctalia msg plugins list"',
        'local COMMAND_ACK_KEY = "director_command_ack"',
        "handleCommand(noctalia.state.get(COMMAND_KEY))",
        'framed:find(" incompatible ", 1, true) == nil',
        "commandFailureDetail(result)",
    ):
        assert public_contract in service

    # Backups are copied through their own temporary file. Moving the primary
    # away first would leave a crash window in which restart recreates defaults.
    assert "noctalia.renameFile(path, backup)" not in service
    assert 'local backupTemporary = backup .. ".tmp"' in service

    for forbidden in (
        "setsid",
        "pkill",
        "/tmp/w-engine",
        "setWallpaperEnabled(",
        "setWallpaper(",
        "saved_wallpaper",
        "w_engine_request",
        "w_engine_status",
    ):
        assert forbidden not in service, forbidden

    shortcut = (ROOT / "shortcut.luau").read_text()
    assert "function onClick()" in shortcut
    assert "function onRightClick()" in shortcut
    assert "function onMiddleClick()" not in shortcut

    widget = (ROOT / "widget.luau").read_text()
    assert "noctalia.togglePanel(target)" in widget
    assert "director_directive" not in widget

    panel = (ROOT / "panel.luau").read_text()
    assert 'native_open = "wallpaper"' in panel
    assert 'wallhaven_open = "noctalia/wallhaven:browser"' in panel
    assert 'w_engine_open = "tadomika_ari/w-engine:w-engine-panel"' in panel
    assert "panel.close()\n                    noctalia.togglePanel(target)" in panel
    assert "director_directive" not in panel

    print("Wallpaper Director Hub contract passed.")


if __name__ == "__main__":
    main()
