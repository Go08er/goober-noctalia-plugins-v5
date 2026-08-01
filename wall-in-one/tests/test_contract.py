#!/usr/bin/env python3
"""Pin Wall-in-One's v0.2 public-provider and pairing contract."""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def dotted_value(document: dict[str, object], key: str) -> object:
    value: object = document
    for component in key.split("."):
        assert isinstance(value, dict) and component in value, f"missing translation: {key}"
        value = value[component]
    return value


def main() -> None:
    manifest_text = (ROOT / "plugin.toml").read_text()
    manifest = tomllib.loads(manifest_text)
    assert manifest["id"] == "goober/wall-in-one"
    assert manifest["name"] == "Wall-in-One"
    assert manifest["version"] == "0.2.0"
    assert manifest["plugin_api"] == 17
    assert [entry["id"] for entry in manifest["service"]] == ["coordinator"]
    assert [entry["id"] for entry in manifest["widget"]] == ["wall-in-one"]
    assert [entry["id"] for entry in manifest["panel"]] == ["hub"]
    assert [entry["id"] for entry in manifest["shortcut"]] == ["wall-in-one-shortcut"]
    assert manifest["widget"][0]["actions"]["middle"] == "none"
    assert manifest["dependencies"] == ["bash"]

    settings = {entry["key"]: entry for entry in manifest["setting"]}
    for key in (
        "capture_directory",
        "auto_capture",
        "pair_static",
        "sync_colors",
        "color_scheme",
        "palette_output",
        "video_source",
        "video_frame_second",
        "manual_pair_file",
        "workshop_id",
        "workshop_directory",
        "scene_screenshot_delay",
        "extra_provider_panel",
    ):
        assert key in settings
    assert settings["auto_capture"]["default"] is False
    assert settings["pair_static"]["default"] is True
    assert settings["sync_colors"]["default"] is False
    assert settings["capture_directory"]["default"] == ""
    assert settings["capture_directory"]["type"] == "folder"
    assert settings["scene_screenshot_delay"]["min"] == 1
    assert settings["scene_screenshot_delay"]["max"] == 120
    assert manifest["widget"][0]["setting"][0]["type"] == "glyph"

    translations = json.loads((ROOT / "translations" / "en.json").read_text())
    assert dotted_value(translations, "plugin.title") == "Wall-in-One"
    for source in ROOT.glob("*.luau"):
        for key in re.findall(r'noctalia\.tr\("([^"]+)"', source.read_text()):
            dotted_value(translations, key)
    for key in re.findall(r'(?:label_key|description_key) = "([^"]+)"', manifest_text):
        dotted_value(translations, key)

    service = (ROOT / "service.luau").read_text()
    for default_mapping in (
        'left = "native_open"',
        'middle = "wallhaven_open"',
        'right = "w_engine_open"',
    ):
        assert default_mapping in service
    for public_contract in (
        'local STATUS_KEY = "wall_in_one_status"',
        'local COMMAND_KEY = "wall_in_one_command"',
        'local COMMAND_ACK_KEY = "wall_in_one_command_ack"',
        '"noctalia/wallhaven:browser"',
        '"tadomika_ari/w-engine:w-engine-panel"',
        '"noctalia/mpvpaper:picker"',
        'local W_ENGINE_SERVICE = "tadomika_ari/w-engine:start"',
        'local MPVPAPER_SERVICE = "noctalia/mpvpaper:service"',
        'native_next = "wallpaper-next"',
        'native_previous = "wallpaper-previous"',
        'native_random = "wallpaper-random"',
        'w_engine_next = "next"',
        'w_engine_cycle_stop = "cycle-stop"',
        'w_engine_stop = "stop"',
        'mpvpaper_pause = "pause"',
        'mpvpaper_resume = "resume"',
        'mpvpaper_clear_all = "clear-all"',
        '"noctalia msg plugins list"',
        '"noctalia msg color-scheme-set wallpaper "',
        "noctalia.setWallpaper(output, path)",
        'manual_pair = true',
        'capture_current = true',
        'video_capture_pair = true',
        'event == "provider-capabilities-v1"',
        'event == "provider-current-v1"',
        'event == "capture-result-v1"',
        '" all capture-v1 "',
        '" all wall-in-one-probe-v1"',
        'event == "w-engine-cycle-stop" or event == "w-engine-pause"',
        "handleCommand(noctalia.state.get(COMMAND_KEY))",
    ):
        assert public_contract in service, public_contract

    # Backups copy through a temporary file. Moving the primary away first
    # would leave a crash window in which restart recreates defaults.
    assert "noctalia.renameFile(path, backup)" not in service
    assert 'local backupTemporary = backup .. ".tmp"' in service

    # Empty means private plugin storage. Only an explicit absolute directory
    # opts into exporting outside pluginDataDir().
    capture_directory = service[
        service.index("local function captureDirectory()") : service.index(
            "local function configuredVideoSource()"
        )
    ]
    assert "noctalia.pluginDataDir()" in capture_directory
    assert 'directory = dataDirectory .. "/captures"' in capture_directory
    assert 'directory:sub(1, 1) ~= "/"' in capture_directory
    assert "wallpaperDirectory" not in capture_directory

    # Legacy runtime schema 1 is accepted once, normalized to schema 2, and
    # atomically written back without resetting valid observations/pairs.
    runtime_validation = service[
        service.index("local function validateRuntime") : service.index(
            "local function atomicWrite"
        )
    ]
    assert "schema ~= 1 and schema ~= RUNTIME_SCHEMA" in runtime_validation
    assert "schema_version = RUNTIME_SCHEMA" in runtime_validation
    assert "schema == 1" in runtime_validation
    assert 'atomicWrite("runtime.json", runtime)' in service

    # Rendered capture is cooperative: each request gets a private unique PNG,
    # only that exact result is accepted, and every terminal path funnels
    # through finishCapture so staging cleanup and queued work cannot strand.
    assert 'dataDirectory:gsub("/+$", "") .. "/staging"' in service
    assert 'staging_path = stagingPath' in service
    assert "value == request.staging_path" in service
    assert "math.max(60, delay + 60)" in service
    assert "local ADAPTER_PROBE_GRACE_MS = 10000" in service
    assert "clearAdapterState()" in service
    assert 'settingInt("scene_screenshot_delay", 15, 1, 120)' in service
    assert (
        'if not providers.w_engine.adapter_capture or not noctalia.commandExists("ffmpeg") then'
        in service
    )
    assert "local queued = captureQueued[key]" in service
    assert "runCapture(queued)" in service
    capture_result = service[
        service.index("local function receiveCaptureResult") : service.index(
            "local function handleCommand"
        )
    ]
    assert capture_result.count("finishCapture(") >= 2
    assert "runCapture(request)" in capture_result
    update_body = service[service.index("function update()") : service.index("function onConfigChanged()")]
    assert "w_engine_adapter_timeout" in update_body
    assert "finishCapture(key, request" in update_body

    manual_pair = service[
        service.index("local function pairConfiguredStill") : service.index(
            "local function actionAvailability"
        )
    ]
    assert "adapterStagingPath(" in manual_pair
    assert "runCapture({" in manual_pair
    assert "pair_path = source" in manual_pair

    # W Engine rendered capture is adapter-owned. Fallback uses Workshop
    # source/preview files and never inspects or signals a provider process.
    for forbidden in (
        "pgrep",
        "setsid",
        "pkill",
        "/tmp/w-engine",
        "--screenshot",
        "saved_wallpaper",
        "w_engine_request",
        "w_engine_status",
        "data.json",
    ):
        assert forbidden not in service, forbidden

    helper = (ROOT / "scripts" / "capture-still").read_text()
    assert "<video|image|copy>" in helper
    assert 'ffmpeg -nostdin -y -loglevel error -ss "$second"' in helper
    assert 'cp -- "$source" "$temporary"' in helper
    assert 'mv -f -- "$temporary" "$destination"' in helper
    temporary = re.search(r"^temporary=(.+)$", helper, re.MULTILINE)
    assert temporary is not None
    temporary_assignment = temporary.group(1)
    assert "mktemp" in temporary_assignment
    assert 'tmpdir="$destination_dir"' in temporary_assignment
    assert ".part" in temporary_assignment
    assert "extension" not in temporary_assignment
    assert not temporary_assignment.rstrip().endswith((".png", ".jpg", ".webp"))
    assert "validate_image_signature()" in helper
    assert "elif ! validate_image_signature" in helper
    for forbidden in ("linux-wallpaperengine", "pkill", "setsid", "mode=engine"):
        assert forbidden not in helper, forbidden

    panel = (ROOT / "panel.luau").read_text()
    widget = (ROOT / "widget.luau").read_text()
    shortcut = (ROOT / "shortcut.luau").read_text()
    for source in (panel, widget, shortcut):
        assert 'local STATUS_KEY = "wall_in_one_status"' in source
        assert 'local COMMAND_KEY = "wall_in_one_command"' in source
        assert "goober/wallpaper-director" not in source
    for action in (
        "w_engine_next",
        "mpvpaper_toggle",
        "capture_current",
        "video_capture_pair",
        "manual_pair",
        "extra_provider_open",
        "hub_open",
    ):
        assert action in panel
        assert action in widget
    assert 'noctalia.togglePanel(target)' in panel
    assert 'noctalia.togglePanel(target)' in widget
    assert "function onMiddleClick()" in widget
    assert "function onMiddleClick()" not in shortcut
    assert "noctalia.openSettings()" in panel

    readme = (ROOT / "README.md").read_text()
    for statement in (
        "goober/wall-in-one:wall-in-one",
        "goober/wall-in-one:hub",
        "goober/wall-in-one:coordinator",
        "does **not** claim",
        "It never scrapes process arguments",
        "one global palette",
        "explicit lock-screen wallpaper path overrides",
        "mixed,\ntimed static/live scheduler is not implemented yet",
        "pluginDataDir()/captures",
        "unique requested PNG path under\n`pluginDataDir()/staging`",
        "valid schema-1 `runtime.json`",
        "`w-engine-cycle-stop`",
    ):
        assert statement in readme, statement

    adapters = (ROOT / "ADAPTERS.md").read_text()
    for statement in (
        "<staging.png>",
        "must return that exact path",
        "`pluginDataDir()/staging`",
        "1–120 frames",
        "greater of 60\nseconds or the configured frame delay plus 60 seconds",
        "drain any queued work",
    ):
        assert statement in adapters, statement

    print("Wall-in-One v0.2 contract passed.")


if __name__ == "__main__":
    main()
