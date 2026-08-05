#!/usr/bin/env python3
"""Offline contract gate for Wall-in-One 0.8.

The test deliberately avoids a compositor and the network.  It pins the
manifest/state protocols statically, runs each shell helper's local checks,
and exercises the renderer supervisor with disposable fake renderers so PID
ownership, FIFO cleanup, and exact argv remain observable.
"""

from __future__ import annotations

import base64
import errno
import json
import math
import os
import re
import select
import signal
import shutil
import stat
import subprocess
import tempfile
import time
import tomllib
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
ANSI_ESCAPE_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[@-_])")


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def dotted_value(document: dict[str, object], key: str) -> object:
    value: object = document
    for component in key.split("."):
        assert isinstance(value, dict) and component in value, f"missing translation: {key}"
        value = value[component]
    return value


def require_all(source: str, needles: Iterable[str], label: str) -> None:
    for needle in needles:
        assert needle in source, f"{label} is missing {needle!r}"


def luau_function(source: str, name: str) -> str:
    """Return one top-level Luau function without coupling tests to line numbers."""

    match = re.search(
        rf"(?ms)^(?:local\s+)?function\s+{re.escape(name)}\([^\n]*\).*?(?=^(?:local\s+)?function\s+|\Z)",
        source,
    )
    assert match is not None, f"missing top-level Luau function {name}"
    return match.group(0)


def luau_braced_list_entry_count(source: str, marker: str) -> int:
    """Count top-level entries in a simple Luau table while ignoring strings."""

    start = source.find(marker)
    assert start >= 0, f"missing Luau table marker {marker!r}"
    cursor = start + len(marker)
    depth = 1
    quote = ""
    escaped = False
    separators = 0
    has_value_after_separator = False
    while cursor < len(source):
        character = source[cursor]
        cursor += 1
        if quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = ""
            if depth == 1:
                has_value_after_separator = True
            continue
        if character in {'"', "'"}:
            quote = character
            if depth == 1:
                has_value_after_separator = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return separators + (1 if has_value_after_separator else 0)
        elif depth == 1 and character == ",":
            separators += 1
            has_value_after_separator = False
        elif depth == 1 and not character.isspace():
            has_value_after_separator = True
    raise AssertionError(f"unterminated Luau table after {marker!r}")


def test_manifest_and_translations() -> None:
    manifest_source = text("plugin.toml")
    manifest = tomllib.loads(manifest_source)
    assert manifest["id"] == "goober/wall-in-one"
    assert manifest["name"] == "Wall-in-One"
    assert manifest["version"] == "0.8.0"
    assert manifest["plugin_api"] == 17
    # Dependencies are catalog metadata, not an enable-time gate. Providers
    # still fail soft if an installation is incomplete, while curl is honestly
    # advertised for all three bounded online transports.
    assert manifest["dependencies"] == ["bash", "curl", "sha256sum"]
    assert {entry["id"]: entry["entry"] for entry in manifest["service"]} == {
        "coordinator": "service.luau",
        "backend": "backend.luau",
        "renderer": "renderer.luau",
        "motionbgs": "motionbgs.luau",
        "palettes": "palettes.luau",
        "wallhaven": "wallhaven.luau",
    }
    assert [entry["id"] for entry in manifest["widget"]] == ["wall-in-one"]
    assert [entry["id"] for entry in manifest["panel"]] == ["hub"]
    assert [entry["id"] for entry in manifest["shortcut"]] == ["wall-in-one-shortcut"]
    assert manifest["widget"][0]["actions"]["middle"] == "none"
    glyph = {entry["key"]: entry for entry in manifest["widget"][0]["setting"]}["glyph"]
    assert glyph["type"] == "glyph"

    settings = {entry["key"]: entry for entry in manifest["setting"]}
    required = {
        "use_wallhaven",
        "use_motionbgs",
        "backend_binary_path",
        "capture_directory",
        "video_directory",
        "auto_capture",
        "sync_colors",
        "color_scheme",
        "palette_output",
        "wallhaven_api_key",
        "video_source",
        "manual_pair_file",
        "video_frame_second",
        "workshop_id",
        "workshop_directory",
        "scene_screenshot_delay",
        "cycle_interval_minutes",
        "cycle_order",
        "cycle_start_on_load",
        "motionbgs_quality",
        "motionbgs_result_limit",
        "motionbgs_cache_minutes",
        "motionbgs_max_download_mb",
    }
    retired_compatibility_settings = {
        "w_engine_backend",
        "mpvpaper_backend",
        "internal_renderer_layer",
        "mpv_auto_pause_mode",
        "motionbgs_binary_path",
    }
    assert required | retired_compatibility_settings == settings.keys(), sorted(
        (required | retired_compatibility_settings) ^ settings.keys()
    )
    assert "pair_static" not in settings, "pairing is an entry policy, not a global switch"
    retired_renderer_settings = {
        "use_w_engine",
        "use_mpvpaper",
        "use_extra_provider",
        "extra_provider_panel",
        "w_engine_scaling",
        "w_engine_clamp",
        "w_engine_fps",
        "w_engine_volume",
        "w_engine_silent",
        "w_engine_noautomute",
        "w_engine_no_audio_processing",
        "w_engine_disable_particles",
        "w_engine_disable_mouse",
        "w_engine_disable_parallax",
        "w_engine_no_fullscreen_pause",
        "w_engine_fullscreen_pause_only_active",
        "mpv_mute",
        "mpv_hardware_decode",
        "mpv_auto_pause",
        "mpv_options",
    }
    assert retired_renderer_settings.isdisjoint(settings)
    for key in retired_compatibility_settings:
        assert settings[key] == {
            "key": key,
            "type": "string",
            "label_key": "settings.retired_compatibility.label",
            "description_key": "settings.retired_compatibility.description",
            "default": "",
            "advanced": True,
            "visible_when": {
                "key": "capture_directory",
                "values": ["__wall_in_one_retired_setting__"],
            },
        }, f"retired setting {key!r} must remain an inert, impossible-to-show migration shim"
    for source_name in ("panel.luau", "service.luau"):
        source = text(source_name)
        for key in retired_compatibility_settings:
            assert key not in source, (
                f"{source_name} must not read or fall back to retired compatibility key {key!r}"
            )
    for setting in settings.values():
        condition = setting.get("visible_when")
        if condition is not None:
            assert condition["key"] in settings, f"dangling visible_when for {setting['key']}"
    assert (
        settings["scene_screenshot_delay"]["default"],
        settings["scene_screenshot_delay"]["min"],
        settings["scene_screenshot_delay"]["max"],
    ) == (15, 1, 120)
    assert settings["sync_colors"]["default"] is True
    assert settings["cycle_start_on_load"]["default"] is False
    assert (settings["cycle_interval_minutes"]["min"], settings["cycle_interval_minutes"]["max"]) == (
        1,
        43200,
    )
    assert settings["motionbgs_quality"]["default"] == "hd"
    assert settings["backend_binary_path"] == {
        "key": "backend_binary_path",
        "type": "file",
        "label_key": "settings.backend_binary_path.label",
        "description_key": "settings.backend_binary_path.description",
        "default": "",
        "advanced": True,
    }
    assert [item["value"] for item in settings["motionbgs_quality"]["options"]] == ["hd", "4k"]
    for key, default, minimum, maximum in (
        ("motionbgs_result_limit", 48, 1, 48),
        ("motionbgs_cache_minutes", 30, 5, 1440),
        ("motionbgs_max_download_mb", 256, 16, 512),
    ):
        assert (settings[key]["default"], settings[key]["min"], settings[key]["max"]) == (
            default,
            minimum,
            maximum,
        )

    translations = json.loads(text("translations/en.json"))
    assert dotted_value(translations, "plugin.title") == "Wall-in-One"
    for source in ROOT.glob("*.luau"):
        for key in re.findall(r'noctalia\.tr\("([^"]+)"', source.read_text(encoding="utf-8")):
            dotted_value(translations, key)
    for key in re.findall(r'(?:label_key|description_key) = "([^"]+)"', manifest_source):
        dotted_value(translations, key)


def test_schema_document_fixtures() -> None:
    """Pin the public persisted document shapes with readable JSON fixtures."""

    config = {
        "schema_version": 5,
        "gestures": {
            "left": "hub_open",
            "middle": "hub_open",
            "right": "native_next",
        },
        "pairings": {
            "pairing-city-1": {
                "id": "pairing-city-1",
                "label": "City",
                "media": {"kind": "video", "source": "/wallpapers/city.mp4"},
                "still": {"mode": "automatic"},
                "theme": {
                    "mode": "dark",
                    "source": "wallpaper",
                    "selection": "m3-tonal-spot",
                },
                "customized": True,
                "added_at": "2026-08-01 20:00:00",
            }
        },
        "playlists": {
            "playlist-evening-1": {
                "name": "Evening",
                "order": "shuffle",
                "interval_seconds": 900,
                "quick_choice": False,
                "entries": [
                    {
                        "id": "entry-city-1",
                        "pairing_id": "pairing-city-1",
                        "label": "City",
                        "media": {"kind": "video", "source": "/wallpapers/city.mp4"},
                        "still": {"mode": "automatic"},
                        "theme": {
                            "mode": "dark",
                            "source": "wallpaper",
                            "selection": "m3-tonal-spot",
                        },
                        "customized": True,
                        "added_at": "2026-08-01 20:00:00",
                    },
                    {
                        "id": "entry-nord-2",
                        "label": "Nord still",
                        "media": None,
                        "still": {
                            "mode": "selected",
                            "path": "/wallpapers/nord.png",
                        },
                        "theme": {
                            "mode": "light",
                            "source": "builtin",
                            "selection": "Nord",
                        },
                        "customized": True,
                        "added_at": "2026-08-01 20:01:00",
                    },
                ],
            }
        },
        "outputs": {
            "HEADLESS-1": {
                "fallback_playlist": "playlist-evening-1",
                "quick_choice_playlist": "",
                "order": "rotate",
                "interval_seconds": 1800,
                "engines": {
                    "layer": "background",
                    "video": {
                        "enabled": True,
                        "mute": False,
                        "hardware_decode": True,
                        "auto_pause": True,
                        "auto_pause_mode": "ACTIVE",
                        "options": "--profile=fast",
                    },
                    "workshop": {
                        "enabled": True,
                        "fps": 60,
                        "volume": 25,
                        "silent": False,
                        "scaling": "fill",
                        "clamp": "border",
                        "flags": {
                            "noautomute": True,
                            "no_audio_processing": False,
                            "disable_particles": False,
                            "disable_mouse": True,
                            "disable_parallax": False,
                            "no_fullscreen_pause": False,
                            "fullscreen_pause_only_active": True,
                        },
                    },
                },
                "schedules": [
                    {
                        "id": "schedule-evening-upper-1",
                        "name": "Evening upper",
                        "playlist": "playlist-evening-1",
                        "enabled": True,
                        "weekdays": [0, 1, 2, 3, 4, 5, 6],
                        "months": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
                        "start_minute": 1080,
                        "end_minute": 360,
                        "all_day": False,
                    },
                    {
                        "id": "schedule-evening-lower-2",
                        "name": "Evening lower",
                        "playlist": "playlist-evening-1",
                        "enabled": True,
                        "weekdays": [0, 1, 2, 3, 4, 5, 6],
                        "months": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
                        "start_minute": 1080,
                        "end_minute": 360,
                        "all_day": False,
                    },
                ],
            }
        },
    }
    runtime = {
        "schema_version": 6,
        "providers": {},
        "pairs": {},
        "pair_registry": {},
        "runs": {
            "HEADLESS-1": {
                "playlist-evening-1": {
                    "running": True,
                    "paused": False,
                    "parked": False,
                    "current_entry": "entry-city-1",
                    "next_due": 1785632400,
                    "history": ["entry-city-1"],
                    "bag": ["entry-nord-2"],
                    "last_applied_at": "2026-08-01 20:00:00",
                    "last_error": "",
                }
            }
        },
        "output_states": {
            "HEADLESS-1": {
                "active_playlist": "playlist-evening-1",
                "manual_pin": False,
                "active_schedule": "schedule-evening-lower-2",
                "last_transition_at": "2026-08-01 18:00:00",
            }
        },
        "palette": {
            "authority_output": "HEADLESS-1",
            "requested": {
                "mode": "dark",
                "source": "wallpaper",
                "selection": "m3-tonal-spot",
                "output": "HEADLESS-1",
                "playlist": "playlist-evening-1",
                "entry": "entry-city-1",
                "fallback": False,
                "resolution": "requested",
                "applied_at": "",
            },
            "applied": {
                "mode": "dark",
                "source": "wallpaper",
                "selection": "m3-tonal-spot",
                "output": "HEADLESS-1",
                "playlist": "playlist-evening-1",
                "entry": "entry-city-1",
                "fallback": False,
                "resolution": "assumed",
                "applied_at": "2026-08-01 20:00:01",
            },
            "last_error": "",
        },
        "current_workshops": {},
        "last_capture": {},
        "observed_at": "",
        "last_error": "",
    }

    config_round_trip = json.loads(json.dumps(config, sort_keys=True))
    runtime_round_trip = json.loads(json.dumps(runtime, sort_keys=True))
    playlist = config_round_trip["playlists"]["playlist-evening-1"]
    entry_ids = [entry["id"] for entry in playlist["entries"]]
    assert len(entry_ids) == len(set(entry_ids))
    pairing = config_round_trip["pairings"]["pairing-city-1"]
    occurrence = playlist["entries"][0]
    assert occurrence["pairing_id"] == pairing["id"]
    assert occurrence["id"] != pairing["id"]
    for field in ("label", "media", "still", "theme", "customized"):
        assert occurrence[field] == pairing[field]
    assert "pairing_id" not in pairing, "catalog records are reusable bundles, not occurrences"
    run = runtime_round_trip["runs"]["HEADLESS-1"]["playlist-evening-1"]
    assert run["current_entry"] in entry_ids
    assert set(run["history"] + run["bag"]) <= set(entry_ids)
    output = config_round_trip["outputs"]["HEADLESS-1"]
    assert output["order"] == "rotate" and output["interval_seconds"] == 1800
    assert output["engines"]["video"]["auto_pause_mode"] == "ACTIVE"
    assert output["engines"]["workshop"]["flags"]["disable_mouse"] is True
    upper_schedule, lower_schedule = output["schedules"]
    assert upper_schedule["start_minute"] > upper_schedule["end_minute"], (
        "fixture must exercise overnight scheduling"
    )
    assert upper_schedule["months"] == list(range(1, 13))
    assert lower_schedule["months"] == list(range(1, 13))
    assert "priority" not in upper_schedule and "priority" not in lower_schedule
    assert runtime_round_trip["output_states"]["HEADLESS-1"]["active_schedule"] == lower_schedule["id"], (
        "the lower matching schedule row must win"
    )

    one_entry_run = {
        **run,
        "running": False,
        "paused": False,
        "parked": True,
        "current_entry": entry_ids[0],
        "next_due": 0,
        "history": [entry_ids[0]],
        "bag": [],
    }
    assert one_entry_run["parked"] and not one_entry_run["running"]
    assert one_entry_run["next_due"] == 0


def test_coordinator_contract() -> None:
    service = text("service.luau")

    # Luau keeps chunk-scope locals live for the whole service and hard-fails
    # compilation at 200 registers. Helpers therefore live on the private
    # wallInOne namespace; retain headroom for Noctalia's loader and future
    # state without relying on the manifest linter to catch this runtime limit.
    top_level_locals = re.findall(r"^local\s+(?!function\b)", service, re.MULTILINE)
    assert len(top_level_locals) <= 160, len(top_level_locals)
    assert re.search(r"^local function\s+", service, re.MULTILINE) is None
    lifecycle_callbacks = {"update", "onConfigChanged", "onOutputsChanged", "onIpc", "onExit"}
    top_level_functions = re.findall(r"^function\s+([^\s(]+)", service, re.MULTILINE)
    unexpected_globals = [
        name
        for name in top_level_functions
        if not name.startswith("wallInOne.") and name not in lifecycle_callbacks
    ]
    assert unexpected_globals == [], f"coordinator leaked global helpers: {unexpected_globals}"
    assert len(top_level_functions) == len(set(top_level_functions)), "coordinator redefined a top-level helper"

    require_all(
        service,
        (
            "local CONFIG_SCHEMA = 5",
            "local RUNTIME_SCHEMA = 6",
            "local MAX_PLAYLISTS = 128",
            "local MAX_PLAYLIST_ENTRIES = 512",
            "local MAX_PAIRINGS = 1024",
            "local MAX_PLAYLIST_RUNS = 4096",
            "local MAX_RUNTIME_OUTPUTS = 64",
            "local MAX_PAIR_REGISTRY_ENTRIES = 1024",
            "local MAX_STORAGE_BYTES = 8 * 1024 * 1024",
            "local MAX_PERSISTED_PATH_BYTES = 4096",
            'local PALETTES_COMMAND_KEY = "wall_in_one_palettes_command_v1"',
            'local PALETTES_STATUS_KEY = "wall_in_one_palettes_status_v1"',
            'local WALLHAVEN_COMMAND_KEY = "wall_in_one_wallhaven_command_v1"',
            'local WALLHAVEN_STATUS_KEY = "wall_in_one_wallhaven_status_v1"',
            'local WALLHAVEN_RESULTS_KEY = "wall_in_one_wallhaven_results_v1"',
            'local CONFIG_STATE_KEY = "wall_in_one_config_state_v1"',
            'local RUNTIME_STATE_KEY = "wall_in_one_runtime_state_v1"',
            'local LIBRARY_STATE_KEY = "wall_in_one_library_state_v1"',
        ),
        "coordinator schema and protocol constants",
    )

    assert service.count('noctalia.commandExists("mpvpaper")') == 3
    assert service.count('noctalia.commandExists("linux-wallpaperengine")') == 3
    assert 'noctalia.commandExists("mpv")' not in service
    backend_policy = service[
        service.index("function wallInOne.refreshBackendPolicy") : service.index(
            "function wallInOne.applyIntegrationPolicy"
        )
    ]
    require_all(
        backend_policy,
        (
            'providers.w_engine.command_available = noctalia.commandExists("linux-wallpaperengine")',
            'providers.mpvpaper.command_available = noctalia.commandExists("mpvpaper")',
            'wallInOne.anyOutputEngineEnabled("w_engine")',
            'wallInOne.anyOutputEngineEnabled("mpvpaper")',
            "rendererReady",
            "providers.mpvpaper.command_available",
        ),
        "direct renderer executable capability policy",
    )

    direct_gate = service[
        service.index("function wallInOne.internalBackendReady") : service.index(
            "function wallInOne.cachedPair"
        )
    ]
    require_all(
        direct_gate,
        (
            "local engines = wallInOne.outputEngineSettings(output)",
            'provider == "w_engine"',
            'provider == "mpvpaper"',
            "settings.enabled ~= true",
            "rendererStatus.ready ~= true",
            'not noctalia.commandExists("linux-wallpaperengine")',
            'not noctalia.commandExists("mpvpaper")',
        ),
        "per-output direct renderer gate",
    )
    for forbidden in (
        "noctalia msg plugins list",
        "noctalia msg plugin ",
        "tadomika_ari/w-engine",
        "noctalia/mpvpaper",
        "provider-capabilities-v1",
        "provider-current-v1",
        "capture-result-v1",
        "pendingAdapterCaptures",
        "adapterCaptureQueued",
        "requestRenderedCapture",
        "refreshExtraProvider",
        "normalizedExtraPanel",
    ):
        assert forbidden not in service, f"retired cross-plugin runtime surface remains: {forbidden}"

    legacy_gestures = service[
        service.index("local LEGACY_GESTURE_ACTIONS = {") : service.index(
            "-- Parameterized IPC actions"
        )
    ]
    legacy_mappings = {
        "wallhaven_open": "hub_open",
        "w_engine_open": "hub_open",
        "w_engine_next": "cycle_next",
        "w_engine_cycle_stop": "cycle_stop",
        "w_engine_stop": "playback_stop",
        "mpvpaper_open": "hub_open",
        "mpvpaper_pause": "playback_pause",
        "mpvpaper_resume": "playback_resume",
        "mpvpaper_toggle": "playback_toggle",
        "mpvpaper_clear": "playback_stop",
        "mpvpaper_clear_all": "playback_stop_all",
        "extra_provider_open": "no_action",
    }
    for old, replacement in legacy_mappings.items():
        assert f'{old} = "{replacement}"' in legacy_gestures
        assert len(re.findall(rf"(?m)^\s*{re.escape(old)}\s*=", service)) == 1, (
            f"legacy action {old} escaped its migration table"
        )

    gesture_policy = service[
        service.index("local VALID_ACTIONS = {") : service.index("local WORKSHOP_PATHS = {")
    ]
    require_all(
        gesture_policy,
        (
            "audio_volume_down = true",
            "audio_volume_up = true",
            "audio_set_volume = true",
            "local VALID_GESTURE_ACTIONS = {}",
            'if action ~= "audio_set_volume" then',
            "local LEGACY_GESTURE_ACTIONS = {",
        ),
        "gesture and parameterized IPC action separation",
    )
    require_all(
        service,
        (
            "function wallInOne.validWorkshopId(value)",
            'return id:match("^%d+$") ~= nil and #id <= MAX_WORKSHOP_ID_BYTES',
            "if not VALID_GESTURE_ACTIONS[gestures[button]] then",
            "if not VALID_GESTURE_ACTIONS[action] then",
            "gestures[button] = LEGACY_GESTURE_ACTIONS[gestures[button]] or gestures[button]",
        ),
        "central input validation",
    )
    assert service.count('match("^%d+$")') == 1, "Workshop ID validation must stay centralized"

    engine_model = service[
        service.index("function wallInOne.defaultOutputEngines") : service.index(
            "function wallInOne.configuredPlaylistOrder"
        )
    ]
    require_all(
        engine_model,
        (
            "function wallInOne.defaultOutputEngines()",
            'layer = "bottom"',
            "enabled = true",
            "mute = true",
            "hardware_decode = true",
            "auto_pause = true",
            'auto_pause_mode = "FULL"',
            'options = ""',
            "fps = 30",
            "volume = 0",
            "silent = true",
            'scaling = "fill"',
            'clamp = "border"',
            "function wallInOne.normalizedOutputEngines(candidate, fallback)",
            "candidate ~= nil and type(candidate) ~= \"table\"",
            "not VALID_INTERNAL_LAYERS[layer]",
            "not VALID_MPV_AUTO_PAUSE_MODES[autoPauseMode]",
            "#options > 1024",
            'options:find("[%c]") ~= nil',
            "not VALID_W_ENGINE_SCALING[scaling]",
            "not VALID_W_ENGINE_CLAMP[clamp]",
            "fps < 5",
            "fps > 144",
            "volume < 0",
            "volume > 100",
            "flags.no_fullscreen_pause and flags.fullscreen_pause_only_active",
            "function wallInOne.outputEngineSettings(output)",
        ),
        "validated per-output engine model",
    )
    for legacy_setting in (
        "use_mpvpaper",
        "use_w_engine",
        "internal_renderer_layer",
        "mpv_mute",
        "mpv_hardware_decode",
        "mpv_auto_pause",
        "mpv_auto_pause_mode",
        "mpv_options",
        "w_engine_fps",
        "w_engine_volume",
        "w_engine_silent",
        "w_engine_scaling",
        "w_engine_clamp",
    ):
        assert f'"{legacy_setting}"' not in service, f"retired global engine setting remains: {legacy_setting}"

    workshop_options = service[
        service.index("function wallInOne.buildWorkshopRendererCommand") : service.index(
            "function wallInOne.startInternalWorkshop"
        )
    ]
    require_all(
        workshop_options,
        (
            "local engines = wallInOne.outputEngineSettings(command.output)",
            "local workshop = engines.workshop",
            "command.layer = engines.layer",
            "command.fps = workshop.fps",
            "command.volume = workshop.volume",
            "command.scaling = workshop.scaling",
            "command.clamp = workshop.clamp",
            "command.silent = workshop.silent",
            "for _, name in ipairs(WORKSHOP_FLAG_NAMES) do",
            "command[name] = workshop.flags[name]",
        ),
        "per-output Wallpaper Engine renderer-option builder",
    )
    assert service.count("wallInOne.buildWorkshopRendererCommand({") == 2

    entry_model = service[
        service.index("function wallInOne.stableIdentifier") : service.index(
            "function wallInOne.normalizedPlaylists"
        )
    ]
    require_all(
        entry_model,
        (
            "function wallInOne.uniqueIdentifier(used, preferred)",
            "while used[candidate] == true do",
            "function wallInOne.normalizedEntryBundle(candidate)",
            "not wallInOne.validPersistedKey(candidate.id)",
            "local media, mediaValid = wallInOne.normalizedMedia(candidate.media)",
            "local still = wallInOne.normalizedStill(candidate.still, media ~= nil)",
            "local theme = wallInOne.normalizedTheme(candidate.theme)",
            "id = tostring(candidate.id)",
            "media = media",
            "still = still",
            "theme = theme",
            "if candidate.pairing_id ~= nil and tostring(candidate.pairing_id or \"\") ~= \"\" then",
            "normalized.pairing_id = tostring(candidate.pairing_id)",
            "function wallInOne.bundleSignature(candidate)",
            "function wallInOne.pairingFromEntry(entry, pairingId)",
            "function wallInOne.normalizedPairings(candidate)",
            "count > MAX_PAIRINGS",
            "pairing.pairing_id = nil",
            "function wallInOne.reconcilePlaylistPairings(playlists, pairings, createMissing)",
            "entry.pairing_id = nil",
            "pairings[pairingId] = wallInOne.pairingFromEntry(entry, pairingId)",
            "entry.pairing_id = pairingId",
            '"automatic" and hasDynamicMedia',
            '"selected" and wallInOne.validAbsolutePath',
            'mode = "inherit", source = "inherit", selection = ""',
            'source == "wallpaper" and not VALID_COLOR_SCHEMES[selection]',
            'source == "builtin" and not BUILTIN_PALETTES[selection]',
        ),
        "stable entry bundle and palette policy",
    )

    config_model = service[
        service.index("function wallInOne.normalizedPlaylist") : service.index(
            "function wallInOne.validRuntimeKey"
        )
    ]
    require_all(
        config_model,
        (
            "function wallInOne.normalizedPlaylists(candidate)",
            "usedIds[entry.id] == true",
            "totalEntries > MAX_TOTAL_PLAYLIST_ENTRIES",
            "function wallInOne.normalizedMonths(candidate)",
            "function wallInOne.normalizedSchedule(candidate, playlists, allowMissingMonths)",
            "function wallInOne.normalizedOutputs(candidate, playlists, allowMissingScheduleMonths, defaultEngines)",
            "rawMonths = wallInOne.allMonths()",
            "months = months",
            "if rawOutput.order ~= nil then",
            "if rawOutput.interval_seconds ~= nil then",
            "normalizedOutput.order = outputOrder",
            "normalizedOutput.interval_seconds = outputInterval",
            "fallback_playlist = fallback",
            "quick_choice_playlist = quickChoice",
            "schedules = schedules",
            "engines = wallInOne.normalizedOutputEngines(rawOutput.engines, defaultEngines)",
            "if normalizedOutput.engines == nil then",
            "function wallInOne.migrateLegacyReels(candidate)",
            'wallInOne.stableIdentifier("migrated", output, outputCount)',
            "wallInOne.legacyEntryBundle(rawEntry, output, index, usedEntryIds)",
            "if schema ~= 1 and schema ~= 2 and schema ~= 3 and schema ~= 4 and schema ~= CONFIG_SCHEMA then",
            "local migratedEngines = if schema < CONFIG_SCHEMA then wallInOne.defaultOutputEngines() else nil",
            "pairings = wallInOne.normalizedPairings(candidate.pairings or {})",
            "migratedPairings = candidate.pairings == nil",
            "elseif schema == 4 then",
            "wallInOne.normalizedOutputs(candidate.outputs, playlists, false, migratedEngines)",
            "elseif schema == 3 then",
            "pairings = {}",
            "wallInOne.normalizedOutputs(candidate.outputs, playlists, true, migratedEngines)",
            "elseif schema == 2 then",
            "playlists, outputs = wallInOne.migrateLegacyReels(candidate.reels)",
            "schema_version = CONFIG_SCHEMA",
            "wallInOne.reconcilePlaylistPairings(playlists, pairings, schema ~= CONFIG_SCHEMA or migratedPairings)",
            "pairings = pairings",
            "playlists = playlists",
            "outputs = outputs",
            "if schema == CONFIG_SCHEMA and not migratedPairings then nil else { source_schema = schema }",
        ),
        "schema-5 per-output engine model and schema-2-through-4 migration",
    )
    assert "candidate.priority" not in config_model
    assert "schedule.priority" not in config_model
    for retired_setting in (
        "internal_renderer_layer",
        "use_mpvpaper",
        "mpv_mute",
        "mpv_hardware_decode",
        "mpv_auto_pause",
        "mpv_auto_pause_mode",
        "mpv_options",
        "use_w_engine",
        "w_engine_fps",
        "w_engine_volume",
        "w_engine_silent",
        "w_engine_noautomute",
        "w_engine_no_audio_processing",
        "w_engine_disable_particles",
        "w_engine_disable_mouse",
        "w_engine_disable_parallax",
        "w_engine_no_fullscreen_pause",
        "w_engine_fullscreen_pause_only_active",
        "w_engine_scaling",
        "w_engine_clamp",
    ):
        assert f'getConfig("{retired_setting}")' not in service, (
            f"schema-5 migration reads removed manifest setting {retired_setting!r}"
        )
    require_all(
        service,
        (
            "if sourceConfigSchema ~= nil and sourceConfigSchema <= 2 then",
            "wallInOne.refineLegacyEntryPairing()",
            "wallInOne.preserveLegacyCurrentPairs()",
        ),
        "schema-3 migration preservation boundary",
    )

    runtime_model = service[
        service.index("function wallInOne.playlistEntryIds") : service.index("function wallInOne.atomicWrite")
    ]
    require_all(
        runtime_model,
        (
            "function wallInOne.normalizedRun(candidate, playlist)",
            "function wallInOne.normalizedRuns(candidate)",
            "function wallInOne.legacyIndexToEntryId(playlist, rawIndex)",
            "function wallInOne.migrateLegacyCycles(candidate)",
            "local currentEntry = wallInOne.legacyIndexToEntryId(playlist, rawState.cursor) or \"\"",
            "local parked = #playlist.entries == 1 and currentEntry ~= \"\"",
            "running = rawState.running == true and not parked",
            "paused = rawState.paused == true and not parked",
            "next_due = if parked then 0 else",
            "current_entry = currentEntry",
            "history = history",
            "bag = bag",
            "function wallInOne.normalizedOutputStates(candidate)",
            "function wallInOne.normalizedPaletteRuntime(candidate)",
            "authority_output = authority",
            "requested = requested",
            "applied = applied",
            "playlist = wallInOne.boundedDetail(value.playlist or \"\")",
            "entry = wallInOne.boundedDetail(value.entry or \"\")",
            "fallback = value.fallback == true",
            'tostring(value.resolution or "") == "degraded"',
            'tostring(value.resolution or "") == "assumed"',
            'tostring(value.resolution or "") == "pending"',
            "if schema ~= 1 and schema ~= 2 and schema ~= 3 and schema ~= 4 and schema ~= 5 and schema ~= RUNTIME_SCHEMA then",
            "if schema == RUNTIME_SCHEMA then",
            "runs = wallInOne.normalizedRuns(candidate.runs)",
            "outputStates = wallInOne.normalizedOutputStates(candidate.output_states)",
            "runs, outputStates = wallInOne.migrateLegacyCycles",
            "schema_version = RUNTIME_SCHEMA",
            "runs = runs",
            "output_states = outputStates",
            "palette = palette",
        ),
        "schema-6 stable-ID runtime and schema-1-through-5 migration",
    )

    storage = service[
        service.index("function wallInOne.atomicWrite") : service.index("function wallInOne.statusSnapshot")
    ]
    require_all(
        storage,
        (
            "if #encoded + 1 > MAX_STORAGE_BYTES then",
            "(tonumber(info.size) or 0) > MAX_STORAGE_BYTES",
            "function wallInOne.stageDocument(name, value)",
            'local staged = path .. ".next"',
            "function wallInOne.backupDocument(name)",
            "function wallInOne.recoverDocumentTransaction()",
            "wallInOne.readBoundedRegularFile(path, MAX_STORAGE_BYTES)",
            "wallInOne.readBoundedRegularFile(backup, MAX_STORAGE_BYTES)",
            'for _, name in ipairs({ "config.json", "runtime.json" }) do',
            "function wallInOne.installDocumentPair(nextConfig, nextRuntime)",
            'wallInOne.stageDocument("config.json", nextConfig)',
            'wallInOne.stageDocument("runtime.json", nextRuntime)',
            'wallInOne.backupDocument("config.json")',
            'wallInOne.backupDocument("runtime.json")',
            "config_schema = CONFIG_SCHEMA",
            "runtime_schema = RUNTIME_SCHEMA",
            "return wallInOne.recoverDocumentTransaction()",
            "wallInOne.refineLegacyEntryPairing()",
            "wallInOne.preserveLegacyCurrentPairs()",
            "wallInOne.installDocumentPair(config, runtime)",
        ),
        "bounded crash-recoverable paired document migration",
    )
    assert storage.count("wallInOne.readBoundedRegularFile(") >= 4
    assert "noctalia.readFile(path)" not in storage
    assert "noctalia.readFile(backup)" not in storage

    config_domain = service[
        service.index("function wallInOne.configDomainSnapshot") : service.index(
            "function wallInOne.runtimeDomainSnapshot"
        )
    ]
    require_all(
        config_domain,
        (
            "schema_version = CONFIG_SCHEMA",
            "pairings = config.pairings",
            "playlists = config.playlists",
            "outputs = config.outputs",
        ),
        "revisioned already-normalized config-domain payload",
    )
    assert "settings =" not in config_domain

    runtime_domain = service[
        service.index("function wallInOne.runtimeDomainSnapshot") : service.index(
            "function wallInOne.libraryDomainSnapshot"
        )
    ]
    require_all(
        runtime_domain,
        (
            "schema_version = RUNTIME_SCHEMA",
            "runs = runtime.runs",
            "output_states = runtime.output_states",
            "palette = runtime.palette",
            "colors = colors",
            "last_capture = runtime.last_capture",
        ),
        "revisioned runtime-domain payload",
    )

    status = service[
        service.index("function wallInOne.statusSnapshot") : service.index("function wallInOne.markStateDomain")
    ]
    require_all(
        status,
        (
            "protocol = 4",
            "instance_id = SERVICE_NONCE",
            "gestures = wallInOne.cloneGestures(config.gestures)",
            "settings = wallInOne.settingsSnapshot()",
            "providers = providers",
            "config = { key = CONFIG_STATE_KEY, revision = domainPublications.config.revision }",
            "runtime = { key = RUNTIME_STATE_KEY, revision = domainPublications.runtime.revision }",
            "library = { key = LIBRARY_STATE_KEY, revision = domainPublications.library.revision }",
            "captures = wallInOne.activeCapturesSnapshot()",
        ),
        "lightweight coordinator lifecycle status",
    )
    settings_snapshot = service[
        service.index("function wallInOne.settingsSnapshot()") : service.index("function wallInOne.storagePath")
    ]
    require_all(
        settings_snapshot,
        (
            'if type(settingsSnapshotCache) == "table" then',
            'use_wallhaven = wallInOne.settingBool("use_wallhaven", true)',
            'use_motionbgs = wallInOne.settingBool("use_motionbgs", true)',
            'sync_colors = wallInOne.settingBool("sync_colors", true)',
            "settingsSnapshotCache = snapshot",
        ),
        "cached bounded settings snapshot",
    )
    for retired in ("extra_provider", "w_engine_backend", "mpvpaper_backend", "internal_renderer_layer", "mpv_mute"):
        assert retired not in settings_snapshot
    for heavy in (
        "playlists =",
        "outputs =",
        "renderer =",
        "motionbgs =",
        "palettes =",
        "wallhaven =",
        "runs =",
        "output_states =",
        "pairs =",
    ):
        assert heavy not in status, f"lightweight status leaked heavy field {heavy!r}"

    config_changed = service[
        service.index("function onConfigChanged()") : service.index("function onOutputsChanged()")
    ]
    assert 'wallInOne.markStateDomain("config")' not in config_changed
    assert "wallInOne.publishStatus()" not in config_changed
    assert "settingsSnapshotCache = nil" in config_changed
    assert config_changed.index("wallInOne.refreshAvailability()") < config_changed.index("settingsSnapshotCache = nil")
    require_all(
        config_changed,
        (
            "wallInOne.applyIntegrationPolicy()",
            "wallInOne.currentLibraryRootsSignature()",
            "libraryRefreshPending = true",
            "wallInOne.refreshAvailability()",
            "settingsStatusPublishPending = true",
        ),
        "bounded settings-change reconciliation",
    )
    assert "wallInOne.refreshLibrary()" not in config_changed
    assert "wallInOne.ensureImageManagedDirectories()" not in config_changed
    assert "wallInOne.probeColorScheme()" not in config_changed

    update = service[service.index("function update()") : service.index("function onConfigChanged()")]
    require_all(
        update,
        (
            "if libraryRefreshPending then",
            "libraryRefreshPending = false",
            "wallInOne.ensureImageManagedDirectories()",
            "wallInOne.refreshLibrary()",
            "if settingsStatusPublishPending then",
            "settingsStatusPublishPending = false",
            "wallInOne.publishStatus()",
            "return",
        ),
        "deferred path-sensitive library refresh",
    )

    publish = service[
        service.index("function wallInOne.publishStatus") : service.index("function wallInOne.setActionError")
    ]
    require_all(
        publish,
        (
            "wallInOne.flushStateDomains()",
            "local signature = noctalia.json.encode(snapshot)",
            "signature == lastStatusSignature",
            "return false",
            "snapshot.sequence = statusSequence",
            "noctalia.state.set(STATUS_KEY, snapshot)",
        ),
        "lightweight native status delta suppression",
    )

    domain_publish = service[
        service.index("function wallInOne.publishStateDomain") : service.index("function wallInOne.publishStatus")
    ]
    require_all(
        domain_publish,
        (
            'publication.dirty ~= true',
            "publication.revision += 1",
            "protocol = 1",
            "instance_id = SERVICE_NONCE",
            "revision = publication.revision",
            "noctalia.state.set(publication.key, snapshot)",
            "publication.dirty = false",
            'wallInOne.publishStateDomain("config", wallInOne.configDomainSnapshot())',
            'wallInOne.publishStateDomain("runtime", wallInOne.runtimeDomainSnapshot())',
            'wallInOne.publishStateDomain("library", wallInOne.libraryDomainSnapshot())',
        ),
        "dirty, revisioned domain publication",
    )
    assert "semanticSignature" not in service, "state publication must not recursively sign bounded domains in Luau"
    color_probe = service[
        service.index("function wallInOne.probeColorScheme") : service.index(
            "-- Local media and Steam Workshop discovery"
        )
    ]
    require_all(
        color_probe,
        (
            'wallInOne.markStateDomain("runtime")',
            "wallInOne.persistRuntimeIfChanged(false)",
            "wallInOne.publishStatus()",
        ),
        "mode/error-aware color observation publication",
    )
    availability = service[
        service.index("function wallInOne.refreshAvailability") : service.index(
            "function wallInOne.probeColorScheme"
        )
    ]
    require_all(
        availability,
        (
            "lastAvailabilityRefreshAt = wallInOne.nowSeconds()",
            'providers.noctalia_cli = noctalia.commandExists("noctalia")',
            'providers.w_engine.steam_available = noctalia.commandExists("steam")',
            "wallInOne.applyIntegrationPolicy()",
            "wallInOne.persistRuntimeIfChanged(false)",
            "wallInOne.publishStatus()",
        ),
        "direct executable and bundled-service availability refresh",
    )
    assert "runAsync" not in availability

    scheduler = service[
        service.index("function wallInOne.playlistEntryIds") : service.index(
            "function wallInOne.captureCurrentBacking"
        )
    ]
    require_all(
        scheduler,
        (
            "function wallInOne.entryIndexById(playlist, entryId)",
            "function wallInOne.effectivePlaylistOrder(output, playlist)",
            "function wallInOne.effectivePlaylistInterval(output, playlist)",
            "function wallInOne.setOutputPlaylistOptions(output, intervalSeconds, order, inherit)",
            "if inherit == true then",
            "outputConfig.order = nil",
            "outputConfig.interval_seconds = nil",
            'wallInOne.saveConfig(nextConfig, "output-options")',
            "function wallInOne.selectPlaylistEntryId(playlist, state, direction, order)",
            'elseif order == "shuffle" then',
            "state.current_entry",
            "state.history",
            "state.bag",
            "advancePlaylist = function(output, playlistId, direction, options)",
            "local restoreCurrent = options.restore_current == true",
            "wallInOne.effectivePlaylistOrder(selectedOutput, playlist)",
            'if not restoreCurrent and direction ~= "previous" then',
            "if restoreCurrent then",
            "then restoredNextDue",
            "elseif ok == true and #playlist.entries == 1 then",
            "current.running = false",
            "current.paused = false",
            "current.parked = true",
            "current.next_due = 0",
            "function wallInOne.setPlaylistRunState(output, playlistId, action, manualPin, deferApply)",
            "if deferApply == true then",
            "state.running = #playlist.entries > 1",
            'local ownedState = type(owned) == "table" and tostring(owned.state or "") or ""',
            'ownedState == "running" or ownedState == "paused"',
            "function wallInOne.placeSchedule(output, scheduleId, anchorId, placement)",
            'placement ~= "before" and placement ~= "after"',
            "local moving = table.remove(schedules, sourceIndex)",
            'table.insert(schedules, if placement == "before" then anchorIndex else anchorIndex + 1, moving)',
            'if not wallInOne.saveConfig(nextConfig, "schedule-place") then',
            "scheduleReevaluationPending[output] = true",
            "function wallInOne.scheduleMatches(schedule, weekday, month, dayOfMonth, minute)",
            "function wallInOne.monthEnabled(schedule, month)",
            "local previousWeekday = (weekday + 6) % 7",
            "local previousMonth = if dayOfMonth == 1 then ((month + 10) % 12) + 1 else month",
            "wallInOne.monthEnabled(schedule, previousMonth)",
            "function wallInOne.winningScheduleAt(outputConfig, weekday, month, dayOfMonth, minute)",
            "function wallInOne.winningSchedule(outputConfig)",
            "winner = schedule",
            "if state.manual_pin == true then",
            "function wallInOne.resumeOutputSchedule(output)",
            "state.manual_pin = false",
        ),
        "stable-ID playlist, output overrides, and ordered calendar schedule engine",
    )
    assert scheduler.count("wallInOne.effectivePlaylistInterval(selectedOutput, playlist)") == 2
    assert "schedule.priority" not in scheduler

    update = service[
        service.index("function update()") : service.index("function onConfigChanged()")
    ]
    require_all(
        update,
        (
            'local clockSignature = noctalia.formatTime("%Y-%m-%d %H:%M")',
            "local minuteChanged = clockSignature ~= scheduleClockSignature",
            "if (minuteChanged or next(scheduleReevaluationPending) ~= nil) and not scheduledBatchActive then",
            "if minuteChanged or scheduleReevaluationPending[output] == true then",
            "scheduleReevaluationPending[output] = nil",
            "for output in pairs(config.outputs) do",
            "table.sort(scheduledOutputs)",
            "wallInOne.reevaluateOutputSchedule(output, false, true)",
            "local scheduledStarts = {}",
            "for output, state in pairs(runtime.output_states) do",
            "runtime.runs[output]",
            "run.running == true",
            "run.paused ~= true",
            "for _, restore in ipairs(startupRestoreQueue) do",
            "dueByOutput[restore.output] ~= true",
            "startupRestoreQueue = {}",
            "table.sort(dueOutputs",
            "scheduledBatchActive = true",
            "local function applyNext()",
            'advancePlaylist(due.output, due.playlist_id, "next", {',
            "palette_allowed = due.output == paletteWinner",
            "restore_current = due.restore_current == true",
            "on_complete = applyNext",
        ),
        "minute-boundary schedules and sorted due-output batching",
    )

    require_all(
        service,
        (
            "local startupRestoreQueue = {}",
            'if wallInOne.settingBool("cycle_start_on_load", false) then',
            'wallInOne.entryIndexById(playlist, tostring(run.current_entry or ""))',
            "#playlist.entries > 1 and currentIndex ~= nil and savedDue > resumedAt",
            "run.next_due = savedDue",
            "table.insert(startupRestoreQueue",
            "restore_current = true",
            "run.next_due = resumedAt",
        ),
        "start-on-load current-entry restoration without rotation advance",
    )

    commands = service[
        service.index("function wallInOne.handleCommand") : service.index("function update()")
    ]
    require_all(
        commands,
        (
            'kind == "playlist_create"',
            'kind == "playlist_rename"',
            'kind == "playlist_duplicate"',
            'kind == "playlist_delete"',
            'kind == "playlist_assign"',
            'kind == "playlist_options"',
            'kind == "output_options"',
            "request.inherit == true",
            'kind == "output_engines"',
            "engines = request.engines",
            "wallInOne.saveOutputEngines(request.output, engines)",
            'kind == "pairing_save"',
            'kind == "pairing_reset"',
            'kind == "playlist_add_pairing"',
            'kind == "playlist_add_entry"',
            'kind == "playlist_save_entry"',
            'kind == "playlist_replace_entry"',
            "wallInOne.queuePlaylistEntryReplacement(request)",
            'kind == "playlist_remove_entry"',
            'kind == "playlist_move_entry"',
            'kind == "playlist_place_entry"',
            'kind == "playlist_apply_entry"',
            'kind == "playlist_action"',
            'kind == "schedule_save"',
            'kind == "schedule_delete"',
            'kind == "schedule_place"',
            'kind == "schedule_resume"',
            'kind == "palettes_refresh"',
            'kind == "wallhaven_search"',
            'kind == "wallhaven_detail"',
            'kind == "wallhaven_download"',
            'kind == "wallhaven_clear"',
            'kind == "cycle_add_entry"',
            "wallInOne.addPlaylistEntry(request.output, nil, request.entry)",
        ),
        "playlist API and bounded legacy command translation",
    )
    assert "config.reels" not in commands
    assert "runtime.cycles" not in commands
    assert 'kind == "pairing_delete"' not in commands, (
        "pairing deletion must not remain exposed through the public command protocol"
    )

    replacement_queue = service[
        service.index("function wallInOne.queuePlaylistEntryReplacement") : service.index(
            "function wallInOne.replacePlaylistEntry"
        )
    ]
    require_all(
        replacement_queue,
        (
            "MAX_DEFERRED_PLAYLIST_REPLACEMENTS",
            "playlistReplaceQueueCount >= MAX_DEFERRED_PLAYLIST_REPLACEMENTS",
            "media_source = scalar(",
            "MAX_PERSISTED_PATH_BYTES",
            "playlistReplaceQueueCount += 1",
            "function wallInOne.takePlaylistEntryReplacement()",
        ),
        "fixed-slot primitive-only playlist-entry replacement queue",
    )
    assert re.search(r"^\s*(for|while)\b", replacement_queue, flags=re.MULTILINE) is None
    for forbidden in (
        "table.sort",
        "noctalia.json",
        "wallInOne.editableConfig",
        "wallInOne.saveConfig",
    ):
        assert forbidden not in replacement_queue

    coordinator_update = service[
        service.index("function update()") : service.index("function onConfigChanged()")
    ]
    assert "if wallInOne.applyPendingPlaylistEntryReplacement() then" in coordinator_update
    assert coordinator_update.index("wallInOne.applyPendingPlaylistEntryReplacement()") \
        < coordinator_update.index("wallInOne.drainPostApplyQueue()")

    add_playlist_entry = service[
        service.index("function wallInOne.addPlaylistEntry") : service.index(
            "function wallInOne.effectivePlaylistOrder"
        )
    ]
    require_all(
        add_playlist_entry,
        (
            "function wallInOne.addPlaylistEntry(output, playlistId, rawEntry, beforeId)",
            'local anchor = wallInOne.entryIndexById(nextPlaylist, tostring(beforeId or ""))',
            "table.insert(nextPlaylist.entries, anchor, entry)",
            "table.insert(nextPlaylist.entries, entry)",
        ),
        "library item insertion at the requested playlist zone",
    )
    assert (
        "wallInOne.addPlaylistEntry(request.output, request.playlist_id, request.entry, request.before_id)"
        in commands
    ), "playlist_add_entry must pass the insertion-zone anchor through dispatch"

    output_engine_save = service[
        service.index("function wallInOne.saveOutputEngines") : service.index(
            "function wallInOne.outputState"
        )
    ]
    require_all(
        output_engine_save,
        (
            "wallInOne.knownOutputName",
            "local current = wallInOne.outputEngineSettings(output)",
            "local engines = wallInOne.normalizedOutputEngines(candidate, current)",
            'fallback_playlist = ""',
            'quick_choice_playlist = ""',
            "schedules = {}",
            "outputConfig.engines = engines",
            'wallInOne.saveConfig(nextConfig, "output-engines")',
            "wallInOne.refreshBackendPolicy()",
            "wallInOne.reconcileRendererOwnership()",
        ),
        "validated output_engines save path",
    )

    video_command = service[
        service.index("function wallInOne.startInternalVideo") : service.index(
            "function wallInOne.buildWorkshopRendererCommand"
        )
    ]
    require_all(
        video_command,
        (
            'wallInOne.internalBackendReady("mpvpaper", output)',
            "local engines = wallInOne.outputEngineSettings(output)",
            "local video = engines.video",
            "layer = engines.layer",
            "mute = video.mute",
            "hardware_decode = video.hardware_decode",
            "auto_pause = video.auto_pause",
            "auto_pause_mode = video.auto_pause_mode",
            "options = video.options",
        ),
        "per-output mpvpaper command resolution",
    )

    palette_transport = service[
        service.index("function wallInOne.nextPalettesNonce") : service.index(
            "function wallInOne.actionPanelTarget"
        )
    ]
    require_all(
        palette_transport,
        (
            "function wallInOne.nextPalettesNonce()",
            "palettesCommandSequence = math.max(palettesCommandSequence, previousNonce, statusNonce) + 1",
            "schema = 1",
            'action = "refresh"',
            'action = "preview"',
            "noctalia.state.set(PALETTES_COMMAND_KEY, {",
            'path = if wallInOne.validAbsolutePath(path) then path else ""',
            "The palette worker owns final source validation and publishes",
            "function wallInOne.nextWallhavenNonce()",
            "wallhavenCommandSequence = math.max(wallhavenCommandSequence, previousNonce, statusNonce) + 1",
            'action = action',
            "noctalia.state.set(WALLHAVEN_COMMAND_KEY, command)",
            "command.filters = {",
            "command.target_path = target",
            'command.staging_path = target .. ".wallhaven-" .. tostring(nonce) .. ".stage"',
        ),
        "palette and Wallhaven coordinator payloads",
    )

    require_all(
        service,
        (
            'noctalia.state.watch(PALETTES_STATUS_KEY',
            'noctalia.state.watch(WALLHAVEN_STATUS_KEY',
            'noctalia.state.watch(WALLHAVEN_RESULTS_KEY',
            'noctalia.state.watch(BACKEND_STATUS_KEY',
            'noctalia.state.watch(BACKEND_RESULTS_KEY',
            "paletteAuthorityOutput",
            "runtime.palette",
            "applyGeneration[output]",
            "backendGeneration.w_engine += 1",
            "backendGeneration.mpvpaper += 1",
            "function wallInOne.applyPendingLibraryResult()",
            "local captureQueued = {}",
            "local internalCaptureQueued = {}",
            "local activeCaptureRequests = {}",
        ),
        "coordinator observation and bounded work",
    )
    default_config = service[service.index("local config = {") : service.index("local runtime = {")]
    require_all(
        default_config,
        ('left = "hub_open"', 'middle = "native_open"', 'right = "native_next"'),
        "self-contained clean-install widget mappings",
    )
    backend_bridge = text("backend.luau")
    backend_launcher = text("scripts/backend-provider")
    backend_program = (ROOT.parent / "wall-in-one-backend" / "wall-in-one-backend").read_text(
        encoding="utf-8"
    )
    library_transport = service[
        service.index("function wallInOne.nextBackendNonce()") : service.index(
            "function wallInOne.captureHelper()"
        )
    ]
    require_all(
        library_transport,
        (
            "wallInOne.refreshLibrary = function()",
            "stills = type(library.stills) == \"table\" and library.stills or {}",
            "scanning = true",
            "libraryScanNonce = 0",
            "pendingLibraryResult = nil",
            'action = "library.scan"',
            "instance_id = SERVICE_NONCE",
            "image_root = wallInOne.captureDirectory()",
            "video_root = wallInOne.videoDirectory()",
            "workshop_roots = workshopRoots",
            "function wallInOne.adoptBackendLibraryResult(candidate)",
            "pendingLibraryResult = candidate",
            "function wallInOne.applyPendingLibraryResult()",
            "stills = scanned.stills",
            "provider_installs = scanned.provider_installs",
            "representative_stills = scanned.representative_stills",
            "scanning = false",
        ),
        "process-isolated library scan transport",
    )
    # The coordinator only builds a small request and atomically adopts one
    # already-validated result. Directory walking, sorting, and sidecar parsing
    # must not drift back into its ScriptRuntime.
    assert "noctalia.listDir" not in library_transport
    assert "table.sort" not in library_transport
    assert "stepLibraryScan" not in service
    assert "appendLibraryDirectory" not in service

    require_all(
        backend_bridge,
        (
            "local MAX_RESPONSE_BYTES = 128 * 1024",
            "local MAX_PAGE_BYTES = 128 * 1024",
            "local LIBRARY_PAGE_SIZE = 12",
            "local VALIDATION_BATCH = 8",
            "local PAGED_DOMAINS = {",
            'local REQUIRED_CAPABILITY = "library.scan"',
            'page_action = "library.page"',
            "local function normalizePageSections(operation, sections, domain)",
            'local function ownedPageName(name)',
            "#pages ~= math.ceil(count / domain.page_size)",
            "or not directChildOf(path, transportDirectory)",
            "path:sub(#transportDirectory + 2) ~= expectedName",
            "if described ~= count then",
            'tostring(page.action or "") ~= domain.page_action',
            "#page.items > domain.page_size",
            "while budget > 0 and context.current_item <= #context.current_page do",
            "completedTransport = { operation = operation, result = result }",
        ),
        "bounded incremental backend result bridge",
    )
    assert "stepPaletteValidation" not in backend_bridge
    assert backend_bridge.count("local budget = VALIDATION_BATCH") == 1
    launch_start = backend_bridge.index("local function launchOperation(operation)")
    callback_start = backend_bridge.index(
        "local started = noctalia.runAsync(command, function(result)", launch_start
    )
    rpc_callback = backend_bridge[
        callback_start : backend_bridge.index("end, RPC_TIMEOUT_MS)", callback_start)
    ]
    assert "noctalia.json.decode" not in rpc_callback
    assert "normalizeMediaEntry" not in rpc_callback
    require_all(
        backend_launcher,
        (
            "readonly max_response_bytes=$((128 * 1024))",
            "readonly max_rpc_file_kib=$((64 * 1024 + 128))",
            '[[ $owner == "$(id -u)"',
            '[[ -e $response || -L $response ]]',
            'if ! guard_ready "$guard"',
        ),
        "bounded backend launcher",
    )

    backend_scan = backend_program[
        backend_program.index("def _backend_library_scan(") : backend_program.index(
            "def _backend_remove_pages("
        )
    ]
    for managed_source in ('"managed-wallhaven"', '"managed-auto"'):
        assert backend_scan.index(managed_source) < backend_scan.index(
            'request["image_root"], "image", "user"'
        )
    assert backend_scan.index('"managed-motionbgs"') < backend_scan.index(
        'request["video_root"], "video", "user"'
    )
    require_all(
        backend_program,
        (
            "def _backend_sidecar(",
            "def _backend_automatic_sidecar(",
            'ownership == "managed-motionbgs"',
            'ownership == "managed-wallhaven"',
            'representative_stills["video"][path] = preview',
            'representatives[identifier] = paired_preview',
            "BACKEND_LIBRARY_PAGE_SIZE = 12",
            "BACKEND_MAX_RESPONSE_BYTES = 128 * 1024",
            "BACKEND_MAX_PAGE_BYTES = 128 * 1024",
        ),
        "backend library ownership, pairing, and paging",
    )
    download_fingerprint = service[
        service.index("function wallInOne.completedDownloadFingerprint") : service.index(
            "function wallInOne.shellQuote"
        )
    ]
    require_all(
        download_fingerprint,
        (
            "providerStatus.busy == true",
            'tostring(providerStatus.last_action or "") ~= "download"',
            'tostring(providerStatus.last_error or "") ~= ""',
            "providerStatus.last_completed_nonce",
            'type(download) == "table" and tostring(download.path or "") or ""',
            'tostring(math.floor(nonce)) .. ":" .. tostring(#path) .. ":" .. path',
        ),
        "successful provider download completion fingerprint",
    )
    download_watches = service[
        service.index("noctalia.state.watch(MOTIONBGS_STATUS_KEY") : service.index(
            "noctalia.state.watch(WALLHAVEN_RESULTS_KEY"
        )
    ]
    assert download_watches.count("wallInOne.completedDownloadFingerprint(") == 2
    assert download_watches.count("libraryRefreshPending = true") == 2
    assert "wallInOne.refreshLibrary()" not in download_watches, (
        "provider status callbacks must coalesce directory enumeration onto update()"
    )
    require_all(
        service,
        (
            "local lastMotionDownloadFingerprint",
            "local lastWallhavenDownloadFingerprint",
            "lastMotionDownloadFingerprint = wallInOne.completedDownloadFingerprint(initialMotionBgsStatus)",
            "lastWallhavenDownloadFingerprint = wallInOne.completedDownloadFingerprint(initialWallhavenStatus)",
        ),
        "provider download completion initialization",
    )
    assert "lastMotionDownloadPath" not in service
    assert "lastWallhavenDownloadPath" not in service
    for forbidden in ("pgrep", "pkill", "killall", "setsid", "/proc/"):
        assert forbidden not in service, f"coordinator must not own processes: {forbidden}"


def test_steam_handoff_is_disowned_contract() -> None:
    """Pin the Steam handoff so a cold client boot is never killed or reported.

    Noctalia signals a timed-out command's whole process group, so waiting on
    `steam -applaunch` -- which *is* the client, not a launcher -- killed a cold
    boot at the deadline and surfaced it as a failure.
    """

    service = text("service.luau")
    handoff = service[
        service.index("function wallInOne.disownedHandoff") : service.index(
            "function wallInOne.runOwnedRendererControl"
        )
    ]
    require_all(
        service,
        ('return command .. " >/dev/null 2>&1 </dev/null &"',),
        "handoff must background so the runAsync deadline is unreachable",
    )
    # The URL handler starts Steam when it is down and dispatches when it is up;
    # the bare binary is only a fallback for hosts with no opener at all.
    assert handoff.index('xdg-open " .. wallInOne.shellQuote("steam://run/') < handoff.index(
        'steam -applaunch'
    ), "steam:// handoff must be preferred over the steam binary"
    assert "wallInOne.disownedHandoff(command)" in handoff
    assert "errors.steam_open" not in service, (
        "a disowned handoff has no result to report; only a failure to start is an error"
    )
    for waited in ("result.timedOut", "commandFailureDetail"):
        assert waited not in handoff, f"handoff must not wait on a result: {waited}"


def test_reusable_pairing_catalog_contract() -> None:
    """Pin identity-owned pairings, synchronized snapshots, and application."""

    service = text("service.luau")
    catalog = service[
        service.index("function wallInOne.materializedPlaylistEntry") : service.index(
            "function wallInOne.createPlaylist"
        )
    ]
    require_all(
        catalog,
        (
            "function wallInOne.materializedPlaylistEntry(entry, pairings)",
            'local pairingId = tostring(entry.pairing_id or "")',
            "local pairing = type(pairings) == \"table\" and pairings[pairingId] or nil",
            "local materialized = wallInOne.pairingFromEntry(pairing, entry.id)",
            "materialized.pairing_id = pairingId",
            'materialized.added_at = if tostring(entry.added_at or "") ~= "" then entry.added_at else pairing.added_at',
            "function wallInOne.syncPairingSnapshots(nextConfig, pairingId)",
            "for _, playlist in pairs(nextConfig.playlists) do",
            "for index, entry in ipairs(playlist.entries) do",
            "local snapshot = wallInOne.pairingFromEntry(pairing, entry.id)",
            "snapshot.pairing_id = pairingId",
            "playlist.entries[index] = snapshot",
            "function wallInOne.pairingIdentitySelection(nextConfig, candidate)",
            "local identity = wallInOne.bundleIdentity(candidate)",
            "function wallInOne.collapsePairingIdentity(nextConfig, canonicalId, includeCustomized)",
            "occurrence.pairing_id = canonicalId",
            "nextConfig.pairings[duplicateId] = nil",
            "wallInOne.syncPairingSnapshots(nextConfig, canonicalId)",
            "function wallInOne.catalogPairingForEntry(nextConfig, entry)",
            "wallInOne.pairingIdentitySelection(nextConfig, entry)",
            "function wallInOne.savePairing(rawPairing, customized)",
            "local explicitlyEdited = type(existing) == \"table\"",
            "local matchingId, canCollapse, ambiguous = wallInOne.pairingIdentitySelection(nextConfig, pairing)",
            "id = matchingId",
            "pairing.id = id",
            "nextConfig.pairings[id] = pairing",
            "wallInOne.collapsePairingIdentity(nextConfig, id, true)",
            "wallInOne.collapsePairingIdentity(nextConfig, id, false)",
            'wallInOne.saveConfig(nextConfig, "pairing-save")',
            "function wallInOne.resetPairing(rawPairing)",
            "return wallInOne.savePairing(rawPairing, false) ~= nil",
            "function wallInOne.addPairingToPlaylist(output, playlistId, pairingId, beforeId)",
            "local entry = wallInOne.pairingFromEntry(pairing, entryId)",
            "entry.pairing_id = pairing.id",
            "local anchor = wallInOne.entryIndexById(playlist, tostring(beforeId or \"\"))",
            "table.insert(playlist.entries, anchor, entry)",
            'wallInOne.saveConfig(nextConfig, "playlist-add-pairing")',
        ),
        "identity-owned pairing catalog and playlist occurrence snapshots",
    )

    save_pairing = catalog[
        catalog.index("function wallInOne.savePairing") : catalog.index(
            "function wallInOne.resetPairing"
        )
    ]
    assert save_pairing.index("nextConfig.pairings[id] = pairing") < save_pairing.index(
        "if explicitlyEdited then"
    ) < save_pairing.index('wallInOne.saveConfig(nextConfig, "pairing-save")')
    assert "wallInOne.collapseDefaultPairingIdentity" not in catalog

    playlist_application = service[
        service.index("wallInOne.advancePlaylist = function") : service.index(
            "function wallInOne.upsertSchedule"
        )
    ]
    require_all(
        playlist_application,
        (
            "function wallInOne.savePlaylistEntry(playlistId, rawEntry)",
            "nextConfig.pairings[pairingId] = wallInOne.pairingFromEntry(entry, pairingId)",
            "wallInOne.syncPairingSnapshots(nextConfig, pairingId)",
            "function wallInOne.placePlaylistEntry(playlistId, entryId, anchorId, placement)",
            'placement ~= "before" and placement ~= "after" and placement ~= "end"',
            "local entry = table.remove(playlist.entries, source)",
            'if placement == "end" then',
            'table.insert(playlist.entries, if placement == "after" then anchor + 1 else anchor, entry)',
            'wallInOne.saveConfig(nextConfig, "playlist-entry-place")',
            "function wallInOne.applyPlaylistEntryById(output, playlistId, entryId)",
            "wallInOne.materializedPlaylistEntry(playlist.entries[index], config.pairings)",
        ),
        "linked occurrence editing, atomic placement, and materialized application",
    )
    assert playlist_application.count("wallInOne.materializedPlaylistEntry(") == 2, (
        "rotation and direct application must both resolve the latest catalog bundle"
    )

    recovery_start = service.index("function wallInOne.activePlaylistRunAndEntry")
    renderer_recovery = service[
        recovery_start : service.index("\nwallInOne.cleanupOwnedStaging()", recovery_start)
    ]
    require_all(
        renderer_recovery,
        (
            "wallInOne.materializedPlaylistEntry(playlist.entries[entryIndex], config.pairings)",
            "if not wasReady and rendererStatus.ready == true then",
            'elseif tostring(rendererStatus.last_event or "") == "exited" then',
        ),
        "renderer recovery materializes reusable pairing snapshots",
    )
    assert renderer_recovery.count(
        "local state, entry = wallInOne.activePlaylistRunAndEntry(output)"
    ) == 2


def test_item_default_provenance_contract() -> None:
    """Distinguish synthesized defaults from deliberate per-item overrides."""

    service = text("service.luau")
    panel = text("panel.luau")

    entry_model = service[
        service.index("function wallInOne.normalizedEntryBundle") : service.index(
            "function wallInOne.normalizedPlaylists"
        )
    ]
    require_all(
        entry_model,
        (
            # A newly normalized library/playlist bundle has no override unless
            # the caller deliberately supplies the boolean provenance bit.
            "customized = candidate.customized == true",
            "customized = entry.customized == true",
            "function wallInOne.bundleIdentity(candidate)",
            # Missing provenance has different meaning only inside the legacy
            # pairing-map boundary. Old explicit records remain overrides,
            # while an explicit false survives normalization unchanged.
            "pairing.customized = if rawPairing.customized == nil then true else rawPairing.customized == true",
        ),
        "contextual item-default provenance normalization",
    )

    catalog = service[
        service.index("function wallInOne.pairingIdentitySelection") : service.index(
            "function wallInOne.addPairingToPlaylist"
        )
    ]
    require_all(
        catalog,
        (
            "function wallInOne.pairingIdentitySelection(nextConfig, candidate)",
            "local identity = wallInOne.bundleIdentity(candidate)",
            "local customizedIds = {}",
            "local exactIds = {}",
            "return customizedIds[1], false, true",
            "function wallInOne.collapsePairingIdentity(nextConfig, canonicalId, includeCustomized)",
            "and (includeCustomized == true or pairing.customized ~= true)",
            "occurrence.pairing_id = canonicalId",
            "nextConfig.pairings[duplicateId] = nil",
            "function wallInOne.catalogPairingForEntry(nextConfig, entry)",
            "local canonicalId, canCollapse = wallInOne.pairingIdentitySelection(nextConfig, entry)",
            "wallInOne.collapsePairingIdentity(nextConfig, canonicalId, false)",
            "nextConfig.pairings[id] = wallInOne.pairingFromEntry(entry, id)",
            "function wallInOne.savePairing(rawPairing, customized)",
            "customized = customized ~= false",
            "local matchingId, canCollapse, ambiguous = wallInOne.pairingIdentitySelection(nextConfig, pairing)",
            "if explicitlyEdited then",
            "wallInOne.collapsePairingIdentity(nextConfig, id, true)",
            "wallInOne.collapsePairingIdentity(nextConfig, id, false)",
            "function wallInOne.resetPairing(rawPairing)",
            "return wallInOne.savePairing(rawPairing, false) ~= nil",
        ),
        "identity-owned automatic, explicit, and reset item-profile writes",
    )
    assert "collapseDefaultPairingIdentity" not in catalog
    save_pairing = catalog[
        catalog.index("function wallInOne.savePairing") : catalog.index(
            "function wallInOne.resetPairing"
        )
    ]
    assert save_pairing.index("customized = customized ~= false") < save_pairing.index(
        "nextConfig.pairings[id] = pairing"
    ) < save_pairing.index("if explicitlyEdited then")

    commands = service[
        service.index("function wallInOne.handleCommand") : service.index("function update()")
    ]
    require_all(
        commands,
        (
            'kind == "pairing_save"',
            "wallInOne.savePairing(request.pairing)",
            'kind == "pairing_reset"',
            "wallInOne.resetPairing(request.pairing)",
        ),
        "item-profile command provenance",
    )
    assert 'kind == "pairing_delete"' not in commands
    assert "function wallInOne.deletePairing" not in service

    replacement = service[
        service.index("function wallInOne.replacePlaylistEntry") : service.index(
            "function wallInOne.movePlaylistEntry"
        )
    ]
    require_all(
        replacement,
        (
            "function wallInOne.replacePlaylistEntry(playlistId, entryId, rawEntry)",
            "local previousEntry = index ~= nil and playlist.entries[index] or nil",
            "id = entryId",
            "added_at = if tostring(previousEntry.added_at or \"\") ~= \"\"",
            "customized = true",
            "wallInOne.bundleIdentity(candidate)",
            "wallInOne.pairingIdentitySelection(nextConfig, candidate)",
            "local pairing = wallInOne.pairingFromEntry(candidate, pairingId)",
            "replacement.pairing_id = pairingId",
            "replacement.added_at = candidate.added_at",
            "playlist.entries[index] = replacement",
            'wallInOne.saveConfig(nextConfig, "playlist-entry-replace")',
        ),
        "identity-safe graphical playlist-entry replacement",
    )
    assert "rawEntry.pairing_id" not in replacement, (
        "entry replacement must resolve the selected medium instead of reusing the old pairing id"
    )

    panel_ui_declaration = panel.index("local panelUi = {}")
    open_editor_start = panel.index("local function openLibraryEntryPairing")
    assert panel_ui_declaration < open_editor_start, (
        "the panelUi namespace must be local before the fresh-library edit callback closes over it"
    )
    open_editor = panel[
        open_editor_start : panel.index("local function actionLabel")
    ]
    require_all(
        open_editor,
        (
            'if type(existing) == "table" and existing.customized == true then',
            "beginPairingEditor(kind, existing)",
            "local defaults = panelUi.virtualLibraryPairing(entry, libraryItem, nil)",
            'defaults.id = type(existing) == "table" and tostring(existing.id or "") or ""',
            "beginPairingEditor(kind, defaults)",
        ),
        "customized and fresh library-card edit paths",
    )
    customized_begin = open_editor.index("beginPairingEditor(kind, existing)")
    customized_return = open_editor.index("return", customized_begin)
    default_bundle = open_editor.index(
        "local defaults = panelUi.virtualLibraryPairing(entry, libraryItem, nil)"
    )
    default_identity = open_editor.index("defaults.id =", default_bundle)
    default_begin = open_editor.index("beginPairingEditor(kind, defaults)", default_identity)
    assert customized_begin < customized_return < default_bundle < default_identity < default_begin

    # Namespace tables are intentionally declared at top level. Only inspect
    # member/index expressions in code before each declaration: anchoring the
    # declaration and masking quoted strings/comment tails avoids treating a
    # nested scratch table, documentation, or translation text as a binding
    # defect.
    namespace_declarations = re.finditer(
        r"^local ([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{",
        panel,
        flags=re.MULTILINE,
    )
    quoted = re.compile(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*' ''', re.VERBOSE)
    for declaration in namespace_declarations:
        namespace = declaration.group(1)
        member = re.compile(rf"\b{re.escape(namespace)}\s*(?:\.|\[)")
        for line_number, raw_line in enumerate(
            panel[: declaration.start()].splitlines(),
            start=1,
        ):
            code = quoted.sub("", raw_line).split("--", 1)[0]
            assert member.search(code) is None, (
                f"top-level local table {namespace!r} is used before its declaration "
                f"on panel.luau line {line_number}"
            )

    library_card = panel[
        panel.index("function panelUi.libraryCard") : panel.index(
            "function panelUi.libraryItems"
        )
    ]
    require_all(
        library_card,
        (
            "local customized = type(existing) == \"table\" and existing.customized == true",
            "panelUi.virtualLibraryPairing(entry, metadata, if customized then existing else nil)",
            'local pairingId = if customized then tostring(existing.id or "") else ""',
            'local profileId = type(existing) == "table" and tostring(existing.id or "") or ""',
            "local pairingResetArmed = customized and pendingResetPairingId == profileId",
            "defaultBundle.id = profileId",
            'send({ kind = "pairing_reset", pairing = defaultBundle })',
            'tooltip = if customized',
            'else noctalia.tr("panel.pairings.new")',
            "openLibraryEntryPairing(editableEntry, metadata)",
            'tooltip = noctalia.tr("panel.pairings.reset")',
            'variant = if pairingResetArmed then "primary" else "ghost"',
            'noctalia.tr("panel.pairings.confirm_reset")',
            "panelUi.libraryPaletteSummary(bundle, not customized)",
        ),
        "library-card default and non-destructive override reset",
    )
    assert "pairingDeleteArmed" not in library_card
    assert "pendingDeletePairingId" not in library_card
    reset_controls = library_card[
        library_card.index("if customized then") : library_card.index("if managed then")
    ]
    assert 'kind = "pairing_delete"' not in reset_controls
    assert 'variant = "destructive"' not in reset_controls

    default_bundle = panel[
        panel.index("function panelUi.virtualLibraryPairing") : panel.index(
            "function panelUi.libraryPreviewPath"
        )
    ]
    require_all(
        default_bundle,
        (
            "local useAdaptiveColors = settings().sync_colors ~= false",
            'else { mode = "automatic" }',
            'then { mode = "auto", source = "wallpaper", selection = scheme }',
            'else { mode = "inherit", source = "inherit", selection = "" }',
        ),
        "system default palette policy",
    )
    assert "libraryItem.preview" not in default_bundle
    assert "entry.still_path" not in default_bundle

    resolver = panel[
        panel.index("local function preferredPairingForLibraryEntry") : panel.index(
            "local function actionLabel"
        )
    ]
    require_all(
        resolver,
        (
            "local function preferredPairingForLibraryEntry(existing, candidate)",
            "if existingCustomized ~= candidateCustomized then",
            "local function libraryPairingKey(kind, source)",
            "local function indexedLibraryPairings()",
            "local revision = tonumber(state.revision)",
            "then instance == libraryPairingCache.instance",
            "and revision == libraryPairingCache.revision",
            "and pairings == libraryPairingCache.source",
            "if not dragTokensDirty then",
            "markDragTokensDirty()",
            "return libraryPairingCache.index",
            "return if key ~= nil then indexedLibraryPairings()[key] else nil",
        ),
        "snapshot-indexed deterministic library item profile resolver",
    )
    indexed_resolver = resolver[
        resolver.index("local function indexedLibraryPairings") : resolver.index(
            "local function matchingPairingForLibraryEntry"
        )
    ]
    assert re.search(r"^\s*for\b", indexed_resolver, flags=re.MULTILINE) is None
    assert "sortedPairingIds" not in panel

    palette_names = panel[
        panel.index("local paletteEntryIndexes = {}") : panel.index(
            "local function basename"
        )
    ]
    require_all(
        palette_names,
        (
            "local function paletteEntryIndex(source)",
            "if cached.source ~= values then",
            "sourceItems = values",
            "nextNames = {}",
            "ready = false",
            "return cached.names, cached.ready == true, cached.nameIndex",
            "local function stepPaletteEntryIndexReconciliation()",
        ),
        "snapshot-keyed incremental palette-name cache",
    )

    close_editor = panel[
        panel.index("local function closePairingEditor()") : panel.index(
            "local function preferredPairingForLibraryEntry"
        )
    ]
    require_all(
        close_editor,
        (
            'local hadEditorState = pairingEditorOpen == true or editingPairingId ~= ""',
            "if hadEditorState then",
            "resetEntryDraft()",
        ),
        "idempotent pairing-editor close",
    )
    assert close_editor.index("if hadEditorState then") < close_editor.index("resetEntryDraft()")
    shop_router = panel[
        panel.index("function panelPages.selectShopPage") : panel.index(
            "function panelPages.selectPlaylistPage"
        )
    ]
    assert "resetEntryDraft()" not in shop_router, (
        "shop navigation must not scan palette inventory when no pairing editor is open"
    )

    library_items = panel[
        panel.index("function panelUi.libraryItems") : panel.index(
            "function panelUi.libraryDragSignature"
        )
    ]
    require_all(
        library_items,
        (
            "local sourceItems = if kind == \"static\"",
            "local total = #sourceItems",
            "local last = math.min(total, first + maximum - 1)",
            "for index = first, last do",
            "local sourceItem = sourceItems[index]",
            "add(entry, sourceItem, matchingPairingForLibraryEntry(entry))",
            "return items, currentLibrary, total",
        ),
        "source-authoritative indexed library",
    )
    assert "sortedPairingIds(kind)" not in library_items
    assert "pairingMap()[id]" not in library_items
    assert "still_path = tostring(sourceItem.preview" not in library_items

    library_page = panel[
        panel.index("local function librarySection") : panel.index(
            "local function playlistActionButton"
        )
    ]
    require_all(
        library_page,
        (
            "(page - 1) * LIBRARY_PAGE_SIZE",
            "LIBRARY_PAGE_SIZE",
            "panelUi.appendPageControls(children, total, page",
        ),
        "fixed-size local-library pages",
    )

    library_preview = panel[
        panel.index("function panelUi.libraryPreviewPath") : panel.index(
            "function panelUi.libraryPaletteSummary"
        )
    ]
    require_all(
        library_preview,
        (
            'local path = if tostring(still.mode or "") == "selected"',
            "path = tostring(libraryItem.paired_preview or \"\")",
            "path = tostring(libraryItem.preview or \"\")",
            "local withOutput = entryForOutput(entry, output)",
        ),
        "explicit, paired, provider, and current-output thumbnail precedence",
    )
    assert library_preview.index('tostring(still.mode or "") == "selected"') < library_preview.index(
        "libraryItem.paired_preview"
    ) < library_preview.index("libraryItem.preview") < library_preview.index("entryForOutput(entry, output)")

    pairing_editor = panel[
        panel.index("local function pairingEditor") : panel.index(
            "function panelUi.playlistPairingLibrary"
        )
    ]
    require_all(
        pairing_editor,
        (
            'noctalia.tr("panel.pairings.source_locked")',
            "ui.label({ text = source, fontSize = 9, maxLines = 2 })",
        ),
        "read-only media identity in the pairing editor",
    )
    assert 'key = "pairing-source-"' not in pairing_editor
    still_path_change = pairing_editor.index('entryStillPathDraft = tostring(value or "")')
    preview_request = pairing_editor.index("requestPairingAdaptivePreview", still_path_change)
    assert still_path_change < preview_request < pairing_editor.index("render()", preview_request)

    compact_swatch = panel[
        panel.index("function panelUi.compactPaletteSwatch") : panel.index(
            "local function pairingKindLabel"
        )
    ]
    require_all(
        compact_swatch,
        (
            'ui.glyph({ name = "palette", size = 14, color = "on_surface_variant" })',
            "local colors = normalizedPreviewMode(preview, \"dark\")",
        ),
        "neutral unresolved compact palette cue",
    )
    assert 'fill = token' not in compact_swatch
    assert '"surface", "primary", "secondary", "tertiary"' not in compact_swatch

    pairing_library = panel[
        panel.index("function panelUi.playlistPairingLibrary") : panel.index(
            "local function playlistInsertionZone"
        )
    ]
    require_all(
        pairing_library,
        (
            'for _, kind in ipairs({ "static", "video", "workshop" }) do',
            'if playlistLibraryFilter == "all" or playlistLibraryFilter == kind then',
            "local take = math.min(remaining, math.max(0, kindTotal - kindOffset))",
            "panelUi.appendExplicitGrid(children, items, #items, PLAYLIST_LIBRARY_COLUMNS",
            "panelUi.appendPageControls(",
            "panelUi.libraryThumbnail(",
            "compactPaletteSwatch(bundle, pairingId)",
            'local pairingId = if customized then tostring(existing.id or "") else ""',
            "dragLibraryPairingTokenBySignature[signature]",
            "dragLibraryPairingByToken[dragToken]",
            'dragType = "wio-library-item"',
            "payload = dragToken",
            "previewAncestor = 2",
            "openLibraryEntryPairing(entry, metadata)",
        ),
        "unified visual pairing library",
    )
    assert "playlistPairingDrawer" not in panel
    assert "playlistPairingDrawers" not in panel


def test_renderer_crash_backoff_contract() -> None:
    """Unexpected delayed exits must not turn an armed playlist into a churn loop."""

    service = text("service.luau")
    require_all(
        service,
        (
            "local RENDERER_CRASH_BACKOFF_SECONDS = { 10, 20, 40, 80, 160, 300 }",
            "local RENDERER_CRASH_STABLE_SECONDS = MIN_CYCLE_SECONDS",
            "local rendererExitState = {}",
            "function wallInOne.resetRendererExitState(output)",
            "function wallInOne.noteRendererStarted(output, nonce, observedAt)",
            "function wallInOne.noteUnexpectedRendererExit(output, nonce, observedAt)",
            "function wallInOne.rendererRetryFloor(output)",
        ),
        "transient per-output renderer crash backoff",
    )
    policy_start = service.index("function wallInOne.resetRendererExitState")
    policy = service[
        policy_start : service.index("wallInOne.reconcileRendererOwnership", policy_start)
    ]
    require_all(
        policy,
        (
            'state.start_nonce = tostring(nonce or "")',
            "state.retry_at = math.max(0, math.floor(tonumber(state.retry_at) or 0))",
            'tostring(state.start_nonce) == tostring(nonce or "")',
            "now - startedAt >= RENDERER_CRASH_STABLE_SECONDS",
            "failures = math.min(#RENDERER_CRASH_BACKOFF_SECONDS, failures + 1)",
            "local retryAt = now + RENDERER_CRASH_BACKOFF_SECONDS[failures]",
            "started_at = 0",
            'start_nonce = ""',
            "retry_at = retryAt",
        ),
        "bounded exponential renderer recovery policy",
    )
    assert "noctalia.state.set" not in policy, "crash backoff must remain transient"
    invalidation = service[
        service.index("wallInOne.invalidateCycleIntent = function") : service.index(
            "function wallInOne.resetRendererExitState"
        )
    ]
    assert "wallInOne.resetRendererExitState(output)" in invalidation

    exit_start = service.index('elseif tostring(rendererStatus.last_event or "") == "exited" then')
    exit_recovery = service[exit_start : service.index("wallInOne.publishStatus()", exit_start)]
    require_all(
        exit_recovery,
        (
            "state.next_due = wallInOne.noteUnexpectedRendererExit(output, eventNonce, now)",
            "state.last_error = if rendererError ~= \"\"",
            "runtimeChanged = true",
            "wallInOne.persistRuntimeIfChanged(runtimeChanged)",
        ),
        "durable delayed-exit recovery",
    )
    assert "state.next_due = wallInOne.nowSeconds()" not in exit_recovery
    ready_start = service.index("if not wasReady and rendererStatus.ready == true then")
    ready_recovery = service[ready_start:exit_start]
    assert "math.max(now, wallInOne.rendererRetryFloor(output))" in ready_recovery

    advance = service[
        service.index("wallInOne.advancePlaylist = function") : service.index(
            "function wallInOne.setPlaylistRunState"
        )
    ]
    assert "if ok == true and (#playlist.entries == 1 or appliedMedia == nil) then" in advance
    assert "wallInOne.resetRendererExitState(selectedOutput)" in advance

    acknowledgements = service[
        service.index("function wallInOne.resolveRendererAcknowledgements") : service.index(
            "function wallInOne.queueRendererStop"
        )
    ]
    require_all(
        acknowledgements,
        (
            'tostring(pending.action or ""):match("^start_") ~= nil',
            'tostring(pending.output or "") == tostring(output)',
            'tostring(owned.state or "") ~= "capturing"',
            "wallInOne.finishRendererPending(nonce, true, \"\")",
        ),
        "durable renderer start acknowledgement",
    )
    assert acknowledgements.index('if type(nextStatus.outputs) == "table" then') < acknowledgements.index(
        'if event == "started" then'
    )


def test_coordinator_apply_serialization_contract() -> None:
    """Pin ordering safeguards that are otherwise only visible under load."""

    service = text("service.luau")
    require_all(
        service,
        (
            "local wallpaperApplyInFlight = nil",
            "local wallpaperApplyQueued = {}",
            "local scheduledBatchActive = false",
        ),
        "coordinator transaction state",
    )

    apply_queue = service[
        service.index("function wallInOne.applyPairedStill") : service.index(
            "function wallInOne.reassertPaletteAuthority"
        )
    ]
    require_all(
        apply_queue,
        (
            "if wallpaperApplyInFlight ~= nil then",
            "for index = #wallpaperApplyQueued, 1, -1 do",
            'tostring(queued.output or "all") == outputKey',
            "table.remove(wallpaperApplyQueued, index)",
            'noctalia.tr("errors.capture_replaced")',
            "if #wallpaperApplyQueued >= 64 then",
            'noctalia.tr("errors.apply_queue_full")',
            "table.insert(wallpaperApplyQueued, request)",
            "wallpaperApplyInFlight = current",
            "return wallInOne.runPairedStill(current, function(ok, path, errorMessage)",
            "if wallpaperApplyInFlight == current then",
            "wallpaperApplyInFlight = nil",
            "local nextRequest = table.remove(wallpaperApplyQueued, 1)",
            "start(nextRequest)",
        ),
        "globally serialized wallpaper transaction queue",
    )
    assert apply_queue.index("wallpaperApplyInFlight = current") < apply_queue.index(
        "wallInOne.runPairedStill(current"
    )
    completion = apply_queue[apply_queue.index("return wallInOne.runPairedStill(current") :]
    assert completion.index("wallpaperApplyInFlight = nil") < completion.index(
        "table.remove(wallpaperApplyQueued, 1)"
    )
    # Bypassing this one entry point would silently reintroduce concurrent
    # wallpaper/theme transactions.
    assert service.count("wallInOne.runPairedStill(") == 2

    finish_capture = service[
        service.index("function wallInOne.finishCapture") : service.index("wallInOne.runCapture = function")
    ]
    paired_apply = finish_capture[
        finish_capture.index("if request.pair and pairIsCurrent then") : finish_capture.index(
            "elseif not request.pair and request.notify then"
        )
    ]
    require_all(
        paired_apply,
        (
            "wallInOne.applyPairedStill({",
            "on_complete = function(applied, appliedPath, applyError)",
            "wallInOne.releaseCaptureSlot(key)",
            "wallInOne.drainCaptureQueues(key)",
            "})\n            return",
        ),
        "capture ownership through paired application",
    )
    callback = paired_apply[paired_apply.index("on_complete = function") :]
    assert callback.index("wallInOne.releaseCaptureSlot(key)") < callback.index(
        "type(request.on_complete)"
    )
    assert callback.index("wallInOne.releaseCaptureSlot(key)") < callback.index(
        "wallInOne.drainCaptureQueues(key)"
    )
    before_success = finish_capture[: finish_capture.index("if ok then")]
    assert "wallInOne.releaseCaptureSlot(key)" not in before_success

    advance = service[
        service.index("wallInOne.advancePlaylist = function") : service.index(
            "function wallInOne.setPlaylistRunState"
        )
    ]
    require_all(
        advance,
        (
            "local generation = (tonumber(cycleGeneration[selectedOutput]) or 0) + 1",
            "cycleGeneration[selectedOutput] = generation",
            "cycleApplying[selectedOutput] = generation",
            "if tonumber(cycleGeneration[selectedOutput]) ~= generation then",
            "if cycleApplying[selectedOutput] == generation then",
            "cycleApplying[selectedOutput] = nil",
        ),
        "stale playlist-generation guard",
    )
    assert advance.count("if cycleApplying[selectedOutput] == generation then") == 2
    assert advance.count("cycleApplying[selectedOutput] = nil") == 2
    stale_completion = advance[advance.index("on_complete = function") :]
    assert stale_completion.index("if tonumber(cycleGeneration[selectedOutput]) ~= generation then") < (
        stale_completion.index("local current = wallInOne.playlistRunState")
    )

    schedule_transition = service[
        service.index("function wallInOne.reevaluateOutputSchedule") : service.index(
            "function wallInOne.resumeOutputSchedule"
        )
    ]
    require_all(
        schedule_transition,
        (
            "function wallInOne.reevaluateOutputSchedule(output, force, deferApply)",
            'wallInOne.setPlaylistRunState(output, desired, "start", false, deferApply == true)',
            "return started, if started == true and deferApply == true then desired else nil",
        ),
        "deferred schedule transition",
    )

    update = service[service.index("function update()") : service.index("function onConfigChanged()")]
    schedule_gate = update[
        update.index('local clockSignature = noctalia.formatTime("%Y-%m-%d %H:%M")') : update.index(
            "local dueOutputs = {}"
        )
    ]
    require_all(
        schedule_gate,
        (
            "local scheduledStarts = {}",
            "local minuteChanged = clockSignature ~= scheduleClockSignature",
            "if (minuteChanged or next(scheduleReevaluationPending) ~= nil) and not scheduledBatchActive then",
            "scheduleClockSignature = clockSignature",
            "if minuteChanged or scheduleReevaluationPending[output] == true then",
            "table.sort(scheduledOutputs)",
            "scheduleReevaluationPending[output] = nil",
            "wallInOne.reevaluateOutputSchedule(output, false, true)",
            "table.insert(scheduledStarts, { output = output, playlist_id = playlistId })",
        ),
        "minute-boundary schedule batching",
    )
    batch = update[update.index("if #dueOutputs > 0 and not scheduledBatchActive then") :]
    require_all(
        batch,
        (
            "scheduledBatchActive = true",
            "local function finishBatch()",
            "local function applyNext()",
            'wallInOne.advancePlaylist(due.output, due.playlist_id, "next", {',
            "palette_allowed = due.output == paletteWinner",
            "on_complete = applyNext",
            "scheduledBatchActive = false",
        ),
        "serial scheduled/due playlist launch batch",
    )


def test_dynamic_pair_fingerprint_contract() -> None:
    service = text("service.luau")

    normalized_pair = service[
        service.index("function wallInOne.normalizedPair") : service.index(
            "function wallInOne.normalizedPairMap"
        )
    ]
    require_all(
        normalized_pair,
        (
            "source_size = math.max(0, math.floor(tonumber(candidate.source_size) or 0))",
            "source_mtime = math.max(0, math.floor(tonumber(candidate.source_mtime) or 0))",
        ),
        "normalized dynamic source fingerprint",
    )

    fingerprint = service[
        service.index("function wallInOne.dynamicSourceFingerprint") : service.index(
            "function wallInOne.recordPairRegistry"
        )
    ]
    require_all(
        fingerprint,
        (
            'if dynamicId:sub(1, 6) == "video:" then',
            "info = noctalia.fileInfo(dynamicId:sub(7))",
            "elseif wallInOne.validWorkshopId(dynamicId) then",
            "local _project, directory = wallInOne.findWorkshopProject(dynamicId)",
            'info = noctalia.fileInfo(directory .. "project.json")',
            "if type(info) ~= \"table\" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then",
            "return math.floor(tonumber(info.size) or 0), math.floor(tonumber(info.mtime) or 0)",
        ),
        "video and Workshop source fingerprinting",
    )

    registry_record = service[
        service.index("function wallInOne.recordPairRegistry") : service.index(
            "function wallInOne.recordAppliedPair"
        )
    ]
    require_all(
        registry_record,
        (
            "local sourceSize, sourceMtime = wallInOne.dynamicSourceFingerprint(dynamicId)",
            "source_size = tonumber(sourceSize) or 0",
            "source_mtime = tonumber(sourceMtime) or 0",
            "runtime.pair_registry[tostring(dynamicId)] = record",
            "return record",
        ),
        "cache-only dynamic-pair fingerprint persistence",
    )
    assert "runtime.pairs[" not in registry_record, (
        "recording a prepared representative must not claim an applied output pair"
    )

    applied_record = service[
        service.index("function wallInOne.recordAppliedPair") : service.index(
            "function wallInOne.applyThemePolicy"
        )
    ]
    require_all(
        applied_record,
        (
            "local registry = wallInOne.recordPairRegistry(",
            "runtime.pairs[key] = {",
            "source_size = registry.source_size",
            "source_mtime = registry.source_mtime",
        ),
        "applied-pair projection from the shared registry record",
    )

    cached = service[
        service.index("function wallInOne.cachedPair") : service.index(
            "function wallInOne.selectedStaticPair"
        )
    ]
    require_all(
        cached,
        (
            "local sourceSize, sourceMtime = wallInOne.dynamicSourceFingerprint(dynamicId)",
            "local sourceMatches = sourceSize == nil",
            "tonumber(pair.source_size) == sourceSize",
            "tonumber(pair.source_mtime) == sourceMtime",
            "and sourceMatches",
        ),
        "cached-pair source invalidation",
    )
    assert cached.index("local sourceMatches") < cached.index("and sourceMatches") < cached.index(
        'return path, tostring(pair.capture_method or "cached-pair")'
    )


def test_automatic_pairing_preview_contract() -> None:
    """Prepare adaptive representatives off the panel callback without applying them."""

    panel = text("panel.luau")
    service = text("service.luau")

    descriptor = panel[
        panel.index("local function automaticRepresentativePath") : panel.index(
            "local function requestPairingAdaptivePreview"
        )
    ]
    require_all(
        descriptor,
        (
            'local published = type(root.representative_stills) == "table" and root.representative_stills or nil',
            "if published == nil then",
            'return ""',
            'local values = if kind == "video" then published.video elseif kind == "workshop" then published.workshop else nil',
            'type(values) == "table" and values[source]',
            # previewAbsolutePath is scoped to the preview do-block; reaching it
            # from here requires the exported facade, not the bare local.
            "preview.absolutePath(path) and noctalia.fileInfo(path)",
            'tostring(still.mode or "") == "automatic"',
            'mediaKind ~= "video" and mediaKind ~= "workshop"',
            '"automatic"',
            "media_kind = mediaKind",
            "media_source = mediaSource",
            "path = automaticRepresentativePath(mediaKind, mediaSource)",
        ),
        "source-addressed automatic representative descriptor",
    )
    assert 'savedId ~= ""' not in descriptor, (
        "a fresh library item has no saved pairing id and must still prepare a representative"
    )

    request_preview = panel[
        panel.index("local function requestPairingAdaptivePreview") : panel.index(
            "local function retryPairingAdaptivePreview"
        )
    ]
    require_all(
        request_preview,
        (
            'adaptivePreviewStates[descriptor.signature] = { state = "loading", error = "" }',
            'kind = "palette_preview"',
            'request.kind = "pairing_prepare_still"',
            "request.media_kind = descriptor.media_kind",
            "request.media_source = descriptor.media_source",
            "request.output = if selectedScreen ~= \"\" then selectedScreen else focusedOutput()",
            "send(request)",
            "local function requestAutomaticStillPreparation(kind, source)",
            'capture_only = true',
        ),
        "panel-to-service automatic preview request",
    )
    assert request_preview.index('if descriptor.path ~= "" then') < request_preview.index(
        "request.kind = \"pairing_prepare_still\""
    ), "an already prepared representative must use the direct palette-preview path"
    for forbidden in (
        "noctalia.runAsync(",
        "captureVideoPath(",
        "captureWorkshopFallback(",
        "applyPairedStill(",
    ):
        assert forbidden not in request_preview, (
            f"the panel callback must not perform automatic-still work via {forbidden!r}"
        )

    begin_editor = panel[
        panel.index("local function beginPairingEditor") : panel.index(
            "local function closePairingEditor"
        )
    ]
    require_all(
        begin_editor,
        (
            "loadBundleDraft(pairing, kind)",
            "requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)",
            "requestAutomaticStillPreparation(kind, noctalia.string.trim(entryMediaSourceDraft))",
            "render()",
        ),
        "eager pairing-editor representative request",
    )
    assert begin_editor.index("requestPairingAdaptivePreview(") < begin_editor.index("render()")

    pairing_editor = panel[
        panel.index("local function pairingEditor") : panel.index(
            "function panelUi.playlistPairingLibrary"
        )
    ]
    automatic_change = pairing_editor[
        pairing_editor.index('key = "pairing-still-mode-"') : pairing_editor.index(
            '\n        if entryStillModeDraft == "selected" then',
            pairing_editor.index('key = "pairing-still-mode-"'),
        )
    ]
    require_all(
        automatic_change,
        (
            'entryStillModeDraft = if math.floor(tonumber(index) or 0) == 1 then "selected" else "automatic"',
            "local requestedPalette = requestPairingAdaptivePreview(",
            "currentBundle()",
            "previewPairingId",
            "requestAutomaticStillPreparation(kind, source)",
            "render()",
        ),
        "automatic-mode preview restart",
    )

    queue_preview = service[
        service.index("function wallInOne.queuePairingPreview") : service.index(
            "function wallInOne.startPendingPairingPreview"
        )
    ]
    require_all(
        queue_preview,
        (
            'kind == "video"',
            'kind == "workshop"',
            "wallInOne.validAbsolutePath(source)",
            "wallInOne.validWorkshopId(source)",
            "VALID_COLOR_SCHEMES[scheme]",
            "local captureOnly = request.capture_only == true",
            "not captureOnly and not VALID_COLOR_SCHEMES[scheme]",
            "capture_only = captureOnly",
            "pairingPreviewPending = {",
        ),
        "constant-slot validated pairing-preview queue",
    )
    for forbidden in (
        "captureVideoPath(",
        "captureWorkshopFallback(",
        "noctalia.runAsync(",
        "wallInOne.refreshLibrary(",
    ):
        assert forbidden not in queue_preview, (
            f"the state-watch command callback must not start heavy work via {forbidden!r}"
        )

    start_preview = service[
        service.index("function wallInOne.startPendingPairingPreview") : service.index(
            "function wallInOne.nextWallhavenNonce"
        )
    ]
    require_all(
        start_preview,
        (
            "local request = pairingPreviewPending",
            "pairingPreviewPending = nil",
            'local dynamicId = if kind == "video" then "video:" .. source else source',
            "local cachedPath = wallInOne.cachedPair(dynamicId)",
            "if cachedPath ~= nil then",
            "wallInOne.requestPalettePreview({",
            "if request.capture_only ~= true then",
            'or not wallInOne.settingBool("auto_capture", true)',
            "or wallInOne.captureDirectory() == \"\"",
            "local function completed(ok, path, _errorMessage)",
            "pair = false",
            "notify = false",
            "managed_auto = true",
            "cache_pair = true",
            'capture_key = "pairing-preview"',
            "wallInOne.captureVideoPath(options)",
            "wallInOne.captureWorkshopFallback(options)",
        ),
        "bounded cache-first automatic representative capture",
    )
    assert start_preview.index("wallInOne.cachedPair(dynamicId)") < start_preview.index(
        "wallInOne.captureVideoPath(options)"
    )
    for forbidden in (
        "runtime.pairs",
        "wallInOne.applyPairedStill(",
        "wallInOne.startInternalVideo(",
        "wallInOne.startInternalWorkshop(",
        "wallInOne.applyWallpaper",
        "noctalia.runAsync(",
    ):
        assert forbidden not in start_preview, (
            f"preparing a representative must not mutate playback/wallpaper via {forbidden!r}"
        )

    command_handler = service[
        service.index("function wallInOne.handleCommand") : service.index(
            "-- Noctalia lifecycle"
        )
    ]
    require_all(
        command_handler,
        (
            'elseif kind == "pairing_prepare_still" then',
            "wallInOne.queuePairingPreview(request)",
        ),
        "pairing-preview command dispatch",
    )
    pairing_branch = command_handler[
        command_handler.index('elseif kind == "pairing_prepare_still" then') : command_handler.index(
            'elseif kind == "playlist_add_pairing" then'
        )
    ]
    assert "startPendingPairingPreview" not in pairing_branch
    assert "capture" not in pairing_branch.lower(), (
        "the state watcher may queue intent but must not begin capture"
    )

    update = service[service.index("function update()") : service.index("function onConfigChanged()")]
    require_all(
        update,
        (
            "if pairingPreviewPending ~= nil then",
            "wallInOne.startPendingPairingPreview()",
            "wallInOne.publishStatus()",
            "return",
        ),
        "one-preview-per-update dispatch",
    )
    assert update.index("if pairingPreviewPending ~= nil then") < update.index(
        "if libraryRefreshPending then"
    )

    finish_capture = service[
        service.index("function wallInOne.finishCapture") : service.index(
            "wallInOne.runCapture = function"
        )
    ]
    cache_record = finish_capture[
        finish_capture.index("if request.cache_pair == true then") : finish_capture.index(
            "if request.managed_auto == true then"
        )
    ]
    require_all(
        cache_record,
        (
            "wallInOne.recordPairRegistry(",
            'tostring(request.dynamic_id or "")',
            "request.managed_auto == true",
            "runtime.last_capture.captured_at",
        ),
        "cache-only capture completion",
    )
    assert "runtime.pairs" not in cache_record
    managed_refresh = finish_capture[
        finish_capture.index("if request.managed_auto == true then") : finish_capture.index(
            "if pairIsCurrent or not request.pair then"
        )
    ]
    assert "libraryRefreshPending = true" in managed_refresh
    assert "wallInOne.refreshLibrary()" not in managed_refresh

    run_capture = service[
        service.index("wallInOne.runCapture = function") : service.index(
            "function wallInOne.captureWorkshopFallback"
        )
    ]
    require_all(
        run_capture,
        (
            'local key = tostring(request.capture_key or request.output or "all")',
            "if captureInFlight[key] ~= nil then",
            "captureQueued[key] = request",
            "if request.cache_pair == true then",
            'wallInOne.cachedPair(tostring(request.dynamic_id or ""))',
            "pcall(request.on_complete, true, cachedPath)",
            "noctalia.runAsync(command",
            "end, 60000)",
        ),
        "single-flight bounded capture transport",
    )
    assert run_capture.index("if captureInFlight[key] ~= nil then") < run_capture.index(
        "noctalia.runAsync(command"
    )

    for function_name, next_name in (
        ("function wallInOne.captureWorkshopFallback", "function wallInOne.captureCurrent"),
        ("function wallInOne.captureVideoPath", "function wallInOne.captureConfiguredVideo"),
    ):
        capture_path = service[service.index(function_name) : service.index(next_name)]
        require_all(
            capture_path,
            (
                "local cachePair = options.cache_pair == true",
                "local captureKey = options.capture_key",
                "cache_pair = cachePair",
                "capture_key = captureKey",
            ),
            f"{function_name} cache transport",
        )


def test_capture_scene_freshness_contract() -> None:
    """A completed capture must never pair a scene that changed mid-flight."""

    service = text("service.luau")
    capture_current = service[
        service.index("function wallInOne.captureCurrent") : service.index(
            "function wallInOne.captureVideoPath"
        )
    ]
    require_all(
        capture_current,
        (
            'local owned = output ~= nil and type(rendererStatus.outputs) == "table"',
            'local internalId = type(owned) == "table" and tostring(owned.workshop_id or "") or ""',
            "local id = if wallInOne.validWorkshopId(internalId) then internalId else nil",
            "id = wallInOne.configuredWorkshopId()",
            "local observedInternal = wallInOne.validWorkshopId(internalId) and internalId == tostring(id)",
            "local function captureStillCurrent()",
            "or tonumber(applyGeneration[output]) ~= applyToken",
            "or wallInOne.knownOutputName(output) == nil",
            "if observedInternal then",
            'and currentOwned.backend == "w-engine"',
            'and tostring(currentOwned.workshop_id or "") == tostring(id)',
            'local ready = output ~= nil and wallInOne.internalBackendReady("w_engine", output) == true',
            "local backendToken = backendGeneration.w_engine",
            "return backendGeneration.w_engine == backendToken",
            'and wallInOne.internalBackendReady("w_engine", output) == true',
            "should_apply = captureStillCurrent",
            "and captureStillCurrent()",
        ),
        "owned direct-renderer capture freshness",
    )
    # The direct internal-capture branch and both source-fallback branches carry
    # the same per-output intent predicate.
    assert capture_current.count("should_apply = captureStillCurrent") == 2
    assert capture_current.count("and captureStillCurrent()") == 1
    assert capture_current.count("wallInOne.captureWorkshopFallback({") == 2
    assert capture_current.count("wallInOne.requestInternalCapture({") == 1

    internal_capture = service[
        service.index("wallInOne.requestInternalCapture = function") : service.index(
            "function wallInOne.applyVideoWithPair"
        )
    ]
    require_all(
        internal_capture,
        (
            'local ready, reason = wallInOne.internalBackendReady("w_engine", output)',
            "local function parentStillCurrent()",
            "local function stillCurrent()",
            "should_apply = stillCurrent",
            'spec = { method = "linux-wallpaperengine-fbo-v1" }',
            "staging_path = stagingPath",
            "deadline = wallInOne.nowSeconds() + 60",
            "wallInOne.sendRendererCommand(wallInOne.buildWorkshopRendererCommand({",
            'action = "capture_w_engine"',
            'screenshot_delay = math.min(5, wallInOne.settingInt("scene_screenshot_delay", 15, 1, 120))',
            "ack_timeout_seconds = 45",
            "request.spec = {",
            'mode = "copy"',
            "wallInOne.runCapture(request)",
        ),
        "owned renderer capture and fallback protocol",
    )
    assert "requestRenderedCapture" not in internal_capture
    assert "adapter" not in internal_capture.lower()


def test_managed_library_ownership_contract() -> None:
    service = text("service.luau")
    backend_bridge = text("backend.luau")
    backend_program = (ROOT.parent / "wall-in-one-backend" / "wall-in-one-backend").read_text(
        encoding="utf-8"
    )
    panel = text("panel.luau")
    motionbgs = text("motionbgs.luau")
    wallhaven = text("wallhaven.luau")

    require_all(
        service,
        (
            'local MANAGED_PARENT_DIRECTORY = "Wall-in-One"',
            'local MANAGED_WALLHAVEN_DIRECTORY = "Wallhaven"',
            'local MANAGED_AUTOMATIC_STILLS_DIRECTORY = "Automatic Stills"',
            'local MANAGED_MOTIONBGS_DIRECTORY = "MotionBGS"',
            'return root .. "/" .. MANAGED_PARENT_DIRECTORY .. "/" .. child',
            "wallInOne.wallhavenManagedDirectory()",
            "wallInOne.automaticStillDirectory()",
            "wallInOne.motionBgsManagedDirectory()",
        ),
        "managed library partitions",
    )
    assert 'local MANAGED_DOWNLOAD_SUFFIX = "/Wall-in-One/MotionBGS"' in motionbgs

    root_resolution = service[
        service.index("function wallInOne.captureDirectory") : service.index(
            "function wallInOne.managedChildDirectory"
        )
    ]
    require_all(
        root_resolution,
        (
            'wallInOne.settingString("capture_directory", "")',
            'wallInOne.settingString("video_directory", "")',
            'if configured == "" then',
            'wallInOne.normalizedDirectory(noctalia.expandPath(configured)) or ""',
            "function wallInOne.existingDirectory",
            "local info = noctalia.fileInfo(directory)",
            'type(info) == "table" and info.isDir == true',
        ),
        "explicit independent media roots",
    )
    assert "noctalia.wallpaperDirectory()" not in root_resolution
    assert "noctalia.pluginDataDir()" not in root_resolution
    video_resolution = root_resolution[root_resolution.index("function wallInOne.videoDirectory") :]
    assert "wallInOne.captureDirectory()" not in video_resolution

    managed_initialization = service[
        service.index("function wallInOne.ensureImageManagedDirectories") : service.index(
            "function wallInOne.configuredVideoSource"
        )
    ]
    assert managed_initialization.index("wallInOne.existingDirectory(imageRoot)") < managed_initialization.index(
        "wallInOne.ensureManagedDirectory(entry.path, entry.kind)"
    )

    library_refresh = service[
        service.index("wallInOne.refreshLibrary = function()") : service.index(
            "function wallInOne.captureHelper"
        )
    ]
    require_all(
        library_refresh,
        (
            "image_root = wallInOne.captureDirectory()",
            "video_root = wallInOne.videoDirectory()",
            "wallhaven_directory = wallInOne.wallhavenManagedDirectory()",
            "automatic_stills_directory = wallInOne.automaticStillDirectory()",
            "motionbgs_directory = wallInOne.motionBgsManagedDirectory()",
        ),
        "library scan root transport",
    )

    bounded_reader = service[
        service.index("function wallInOne.readBoundedRegularFile") : service.index(
            "function wallInOne.shellQuote"
        )
    ]
    require_all(
        bounded_reader,
        (
            "local info = noctalia.fileInfo(path)",
            "info.isDir == true",
            "expectedBytes < 1",
            "expectedBytes > maximumBytes",
            "local raw = noctalia.readFile(path)",
            "#raw ~= expectedBytes",
            "#raw > maximumBytes",
        ),
        "bounded regular-file reader",
    )
    assert bounded_reader.index("noctalia.fileInfo(path)") < bounded_reader.index("noctalia.readFile(path)")

    managed_marker = service[
        service.index("function wallInOne.ensureManagedDirectory") : service.index(
            "function wallInOne.ensureImageManagedDirectories"
        )
    ]
    require_all(
        managed_marker,
        (
            "wallInOne.readBoundedRegularFile(markerPath, MAX_MANAGED_MARKER_BYTES)",
            "#raw <= MAX_MANAGED_MARKER_BYTES",
        ),
        "bounded managed-directory marker read",
    )
    assert "noctalia.readFile(markerPath)" not in managed_marker

    scan = backend_program[
        backend_program.index("def _backend_media_entry(") : backend_program.index(
            "def _backend_remove_pages("
        )
    ]
    require_all(
        scan,
        (
            '"ownership": "user"',
            '"managed": False',
            '"deletable": False',
            '_backend_sidecar(path, ".motionbgs.json", "MotionBGS")',
            '_backend_sidecar(path, ".wallhaven.json", "Wallhaven")',
            "_backend_automatic_sidecar(path)",
            'ownership="managed"',
            "managed=True",
            "deletable=True",
        ),
        "fail-closed managed-library classification",
    )
    require_all(
        backend_bridge,
        (
            '(ownership ~= "user" and ownership ~= "managed")',
            '(managed ~= deletable)',
            '(managed and ownership ~= "managed")',
            '(not managed and (ownership ~= "user" or provider ~= "local" or sidecar ~= ""))',
        ),
        "bridge managed-library result validation",
    )

    provider_sidecars = service[
        service.index("function wallInOne.readProviderSidecar") : service.index(
            "function wallInOne.nextBackendNonce"
        )
    ]
    require_all(
        provider_sidecars,
        (
            'local sidecarPath = tostring(path or "") .. suffix',
            "wallInOne.readBoundedRegularFile(sidecarPath, MAX_MANAGED_SIDECAR_BYTES)",
            "#raw <= MAX_MANAGED_SIDECAR_BYTES",
            "tonumber(record.schema) ~= 1",
            'tostring(record.provider or "") ~= provider',
            'tostring(record.plugin or "") ~= "goober/wall-in-one"',
            'tostring(record.path or "") ~= tostring(path or "")',
        ),
        "adjacent provenance authority",
    )
    assert "noctalia.readFile(sidecarPath)" not in provider_sidecars

    automatic_sidecar = service[
        service.index("wallInOne.readManagedStillSidecar = function") : service.index(
            "function wallInOne.writeManagedStillSidecar"
        )
    ]
    require_all(
        automatic_sidecar,
        (
            "wallInOne.readBoundedRegularFile(sidecarPath, MAX_MANAGED_SIDECAR_BYTES)",
            "#raw <= MAX_MANAGED_SIDECAR_BYTES",
        ),
        "bounded automatic-still sidecar read",
    )
    assert "noctalia.readFile(sidecarPath)" not in automatic_sidecar

    managed_lookup = service[
        service.index("function wallInOne.managedLibraryEntry") : service.index(
            "function wallInOne.removeManagedPayload"
        )
    ]
    require_all(
        managed_lookup,
        (
            "entry.id == itemId",
            "entry.managed == true",
            "entry.deletable == true",
        ),
        "fresh opaque managed-item lookup",
    )

    deletion = service[
        service.index("function wallInOne.deleteManagedLibraryItem") : service.index(
            "wallInOne.advancePlaylist = function"
        )
    ]
    require_all(
        deletion,
        (
            "local entry = wallInOne.managedLibraryEntry(itemId)",
            'entry.media_type == "video" and wallInOne.directChildOf(path, wallInOne.motionBgsManagedDirectory())',
            'wallInOne.readProviderSidecar(path, ".motionbgs.json", "MotionBGS")',
            'entry.media_type == "image" and wallInOne.directChildOf(path, wallInOne.wallhavenManagedDirectory())',
            'wallInOne.readProviderSidecar(path, ".wallhaven.json", "Wallhaven")',
            "wallInOne.removeManagedPayload(path, sidecarPath)",
            "wallInOne.removeDeletedPathFromPlaylists(path, entry.media_type)",
            "local pairedStills = if entry.media_type == \"video\"",
            "wallInOne.managedStillsForDynamic(dynamicId)",
            'wallInOne.removeDeletedPathFromPlaylists(still.path, "image")',
        ),
        "current-scan managed deletion dispatch",
    )
    assert "request.path" not in deletion
    assert "removeDeletedPathFromReels" not in service

    managed_cleanup = service[
        service.index("function wallInOne.removeDeletedPathFromPlaylists") : service.index(
            "function wallInOne.clearDeletedPairState"
        )
    ]
    require_all(
        managed_cleanup,
        (
            "for pairingId, pairing in pairs(nextConfig.pairings) do",
            "removedPairings[pairingId] = true",
            "nextConfig.pairings[pairingId] = nil",
            'removedPairings[tostring(entry.pairing_id or "")] or sourceMatches',
            "table.remove(playlist.entries, index)",
            'wallInOne.saveConfig(nextConfig, "managed-delete")',
            'run.current_entry = ""',
            "run.history = retain(run.history)",
            "run.bag = retain(run.bag)",
            "run.running = false",
            "run.next_due = 0",
            "wallInOne.persistRuntimeIfChanged(true)",
        ),
        "managed deletion catalog, occurrence, and runtime cleanup",
    )

    wallhaven_send = service[
        service.index("function wallInOne.wallhavenInstalledPath") : service.index(
            "function wallInOne.actionPanelTarget"
        )
    ]
    require_all(
        wallhaven_send,
        (
            "local item = wallInOne.currentWallhavenItem(request.id)",
            "if wallInOne.wallhavenInstalledPath(item.id) ~= nil then",
            "wallInOne.wallhavenManagedDirectory()",
            "wallInOne.ensureManagedDirectory(directory, \"wallhaven\")",
            'local target = directory .. "/wallhaven-"',
            "command.url = tostring(item.path or item.short_url or \"\")",
            "command.target_path = target",
            'command.staging_path = target .. ".wallhaven-" .. tostring(nonce) .. ".stage"',
        ),
        "coordinator-owned Wallhaven destination",
    )
    assert "request.target_path" not in wallhaven_send
    assert "request.staging_path" not in wallhaven_send

    motionbgs_send = service[
        service.index("function wallInOne.motionBgsInstalledPath") : service.index(
            "function wallInOne.nextPalettesNonce"
        )
    ]
    require_all(
        motionbgs_send,
        (
            'local recent = type(motionBgsStatus) == "table" and motionBgsStatus.last_download or nil',
            'tostring(recent.slug or ""):lower() == slug:lower()',
            'recentSidecar == recentPath .. ".motionbgs.json"',
            'tostring(entry.provider or "") == "MotionBGS"',
            'tostring(entry.provider_id or "") == slug',
            'tostring(entry.quality or ""):lower() == quality',
            "if wallInOne.motionBgsInstalledPath(command.slug, command.quality) ~= nil then",
        ),
        "coordinator managed-library MotionBGS duplicate guard",
    )

    wallhaven_download = wallhaven[
        wallhaven.index("local function downloadOperation") : wallhaven.index(
            "local function handleCommand"
        )
    ]
    require_all(
        wallhaven_download,
        (
            "download only accepts a wallpaper from the current result set",
            "download requires the exact selected Wallhaven media or short URL",
            'local requiredStaging = requiredTarget .. ".wallhaven-" .. tostring(nonce) .. ".stage"',
            "download refuses to overwrite an existing target",
            'image_root = root',
            'target_path = target',
            'short_url = item.short_url',
            'file_size = item.file_size',
            'dimension_x = item.dimension_x',
            'dimension_y = item.dimension_y',
        ),
        "managed Wallhaven backend request boundary",
    )
    assert "renameFile" not in wallhaven_download
    assert "removeFile(target)" not in wallhaven_download

    panel_delete = panel[
        panel.index("function panelUi.libraryCard") : panel.index("function panelUi.libraryItems")
    ]
    require_all(
        panel_delete,
        (
            "local managed = metadata.managed == true and metadata.deletable == true",
            'local itemId = tostring(metadata.id or "")',
            'send({ kind = "library_delete", item_id = itemId })',
        ),
        "opaque managed deletion UI",
    )


def test_palette_inventory_contract() -> None:
    palettes = text("palettes.luau")
    backend_bridge = text("backend.luau")
    backend_program = (ROOT.parent / "wall-in-one-backend" / "wall-in-one-backend").read_text(
        encoding="utf-8"
    )
    require_all(
        palettes,
        (
            'local STATUS_KEY = "wall_in_one_palettes_status_v1"',
            'local COMMAND_KEY = "wall_in_one_palettes_command_v1"',
            'local BACKEND_STATUS_KEY = "wall_in_one_backend_status_v1"',
            'local BACKEND_PALETTE_COMMAND_KEY = "wall_in_one_backend_palette_command_v1"',
            'local BACKEND_PALETTE_RESULTS_KEY = "wall_in_one_backend_palette_results_v1"',
            "local PROTOCOL = 1",
            'local BACKEND_CAPABILITY = "palettes.inventory"',
            "local MAX_PALETTES = 512",
            "local MAX_PREVIEW_SWEEP_ENTRIES = 512",
            "local COMMUNITY_TTL_SECONDS = 6 * 60 * 60",
            "local PREVIEW_HASH_TIMEOUT_MS = 20 * 1000",
            "local PINNED_WALLPAPER = {",
            "local PINNED_BUILTIN = {",
            'base .. "/noctalia/palettes"',
            "local function cacheIsFresh()",
            "local function configuredImageRoot()",
            'noctalia.getConfig("capture_directory")',
            "local function clearInventoryState()",
            "local function deactivateForMissingImageRoot(reason)",
            "local function initializeForImageRoot(root)",
            'lastEvent = "waiting-for-image-directory"',
            'lastEvent = "image-directory-ready"',
            "local function backendSupportsPalettes()",
            "local function requestInventory(force, reason)",
            "local function adoptInventoryResult(candidate)",
            "inventoryRetryForce = inventoryRetryForce or force == true",
            "local effectiveForce = force == true or inventoryRetryForce",
            "pendingInventoryNonce = nextInventoryNonce()",
            "noctalia.state.set(BACKEND_PALETTE_COMMAND_KEY, {",
            "force_refresh = effectiveForce",
            "completedInventoryResult = if type(nextResult) == \"table\" then nextResult else nil",
            "adoptInventoryResult(candidate)",
            'requestInventory(inventoryRetryForce, "backend-ready")',
            "local function previewMetadataFingerprint(path, size, mtime, scheme)",
            "local function previewFingerprint(path, size, mtime, digest, scheme)",
            '"sha256"',
            "local function normalizedSha256(value)",
            "local function ownedPreviewFilename(value)",
            'name:match("^preview%-%d+%-%d+%-%d+%.json$")',
            'name:match("^%.wall%-in%-one%-preview%-%d+%-%d+%-%d+$")',
            "local function sweepOwnedPreviewFiles()",
            "math.min(#names, MAX_PREVIEW_SWEEP_ENTRIES)",
            'local command = "exec sha256sum -- " .. shellQuote(request.path)',
            "request.digest = digest",
            "postDigest ~= request.digest",
            '"umask 077; noctalia theme"',
            '"--both -o"',
            '"&& test -f"',
            "sweepOwnedPreviewFiles()",
            "if nonce == nil or nonce <= lastCommandNonce then",
            'tostring(command.action or "") ~= "refresh"',
            "requestInventory(command.force == true",
            "protocol = PROTOCOL",
            "revision = statusRevision",
            "degraded = errorMessage ~= \"\"",
            "counts = {",
            "palettes = {",
            "wallpaper = if ready then PINNED_WALLPAPER else {}",
            "builtin = if ready then PINNED_BUILTIN else {}",
            "community = communityPalettes",
            "custom = customPalettes",
            "if force ~= true and signature == lastPublishedSignature then",
            "noctalia.state.watch(COMMAND_KEY, handleCommand)",
            "noctalia.state.watch(BACKEND_PALETTE_RESULTS_KEY, function(nextResult)",
            "handleCommand(noctalia.state.get(COMMAND_KEY))",
        ),
        "thin palette inventory client and adaptive-preview protocol",
    )
    # Inventory parsing, directory walking, sorting, cache I/O, and network
    # transport belong to the separately installed Python process. The service
    # watcher only captures one completed result; update adopts it later.
    inventory_client = palettes[
        palettes.index("local function backendSupportsPalettes()") : palettes.index(
            "local function clearInventoryState()"
        )
    ]
    for forbidden in (
        "noctalia.listDir",
        "noctalia.readFile",
        "noctalia.writeFile",
        "noctalia.json.decode",
        "noctalia.runAsync",
        "table.sort",
        "COMMUNITY_URL",
    ):
        assert forbidden not in inventory_client, f"palette inventory client performs backend work via {forbidden}"
    palette_update = palettes[palettes.index("function update()") : palettes.index("function onConfigChanged()")]
    assert "noctalia.runAsync" not in palette_update
    assert "noctalia.json.decode" not in palette_update
    assert "noctalia.http(" not in palettes, "palette ingress must use the bounded process transport"

    require_all(
        backend_bridge,
        (
            'local PALETTE_COMMAND_KEY = "wall_in_one_backend_palette_command_v1"',
            'local PALETTE_RESULTS_KEY = "wall_in_one_backend_palette_results_v1"',
            "local PALETTE_PAGE_SIZE = 16",
            "local pendingOperation = nil",
            "local pendingPaletteOperation = nil",
            "local function publishPaletteResult(nonce, ok, paletteValue, kind, message)",
            "local function beginPaletteValidation(operation, payload)",
            'page_action = "palettes.page"',
            "local function normalizeValidationEntry(context, sectionName, candidate)",
            "local function stepValidation()",
            "local budget = VALIDATION_BATCH",
            "pendingPaletteOperation.nonce",
            '"superseded"',
            "if pendingOperation ~= nil and pendingPaletteOperation ~= nil then",
            'if lastDispatchedAction == "library.scan" then',
            "operation = pendingPaletteOperation",
            "local function handlePaletteCommand(command)",
            "noctalia.state.watch(PALETTE_COMMAND_KEY, handlePaletteCommand)",
        ),
        "bounded palette paging and fixed-slot shared-backend queue",
    )
    assert "table.insert(pending" not in backend_bridge, "backend requests must not accumulate in an unbounded queue"

    require_all(
        backend_program,
        (
            '"library.scan,palettes.inventory,preview.sync,wallhaven.search,wallhaven.detail,wallhaven.download,wallhaven.clear"',
            'PALETTES_COMMUNITY_URL = "https://api.noctalia.dev/palettes"',
            "PALETTES_TTL_SECONDS = 6 * 60 * 60",
            "PALETTES_PAGE_SIZE = 16",
            "PALETTES_MAX_CACHE_BYTES = 2 * 1024 * 1024",
            "PALETTES_MAX_CUSTOM_CANDIDATES = 1024",
            "def _palettes_validate_request(",
            "def _palettes_scan_custom(",
            "def _palettes_cache_candidate(",
            "def _palettes_atomic_replace(",
            "def _palettes_fetch_catalog(",
            '"--max-redirs", "0"',
            "if effective_url != PALETTES_COMMUNITY_URL:",
            "def _palettes_inventory(",
            'event = "refresh-failed"',
            "def _palettes_page_inventory(",
            'elif request["action"] == "palettes.inventory":',
        ),
        "process-isolated palette inventory, cache, and ingress boundary",
    )
    palette_exit = palettes[palettes.index("function onExit(_signal, _reason)") : palettes.index("-- Preserve command monotonicity")]
    require_all(
        palette_exit,
        (
            "cleanupPreviewOperation(activePreviewOperation)",
            "inventoryRetryRequested = false",
            "completedInventoryResult = nil",
            "pendingInventoryNonce = 0",
            "statusRevision = if statusRevision >= MAX_NONCE then 1 else statusRevision + 1",
            "noctalia.state.set(STATUS_KEY, {",
            'last_event = "stopped"',
            "ready = false",
            "available = false",
            'image_root = ""',
            "refreshing = false",
            "degraded = false",
            'source = "none"',
            "wallpaper = 0",
            "builtin = 0",
            "community = 0",
            "custom = 0",
            "palettes = {",
        ),
        "bounded palette-service terminal state",
    )
    assert "publishStatus" not in palette_exit, "palette teardown must not rebuild the full catalog snapshot"
    palette_startup = palettes[palettes.index("local startupImageRoot") :]
    require_all(
        palette_startup,
        (
            "local startupImageRoot, startupImageRootError = configuredImageRoot()",
            "if startupImageRoot ~= nil then",
            "initializeForImageRoot(startupImageRoot)",
            "deactivateForMissingImageRoot(startupImageRootError)",
            "if ready and not communityInFlight then",
            'requestInventory(false, "startup-refresh")',
        ),
        "explicit image-root palette startup gate",
    )
    before_startup_gate = palette_startup[: palette_startup.index("if startupImageRoot ~= nil then")]
    for forbidden in (
        "sweepOwnedPreviewFiles()",
        "requestInventory(",
        "noctalia.pluginDataDir()",
    ):
        assert forbidden not in before_startup_gate, (
            f"palette startup must not perform storage/network work before image-root authorization: {forbidden}"
        )
    for forbidden in (
        "theme-mode-set",
        "color-scheme-set",
        "setWallpaper",
    ):
        assert forbidden not in palettes, f"inventory service must not apply themes: {forbidden}"


def test_backend_binary_discovery_and_setup_contract() -> None:
    """Pin safe, consistent backend discovery without duplicating process work."""

    bridges = {
        "generic backend": text("backend.luau"),
        "MotionBGS compatibility": text("motionbgs.luau"),
        "Wallhaven": text("wallhaven.luau"),
    }
    for label, bridge in bridges.items():
        require_all(
            bridge,
            (
                'local BINARY_NAME = "wall-in-one-backend"',
                'local BACKEND_POINTER_NAME = "backend-path"',
                "local MAX_BACKEND_POINTER_BYTES = 4097",
                "local function validatedExecutable(",
                "local function pointerBinary(",
                "local function configuredBinary(",
            ),
            f"{label} backend discovery",
        )

        path_validation = luau_function(bridge, "validAbsolutePath")
        require_all(
            path_validation,
            (
                '#value > 1',
                'value:sub(1, 1) == "/"',
                'value:find("[%c\\\\]") == nil',
                'not value:find("/../", 1, true)',
            ),
            f"{label} control-safe absolute path validation",
        )

        executable_validation = luau_function(bridge, "validatedExecutable")
        require_all(
            executable_validation,
            (
                "validAbsolutePath(path)",
                "noctalia.fileInfo(path)",
                "info.isDir == true",
                "(tonumber(info.size) or 0) <= 0",
                "noctalia.commandExists(path) ~= true",
            ),
            f"{label} absolute regular non-empty executable validation",
        )

        pointer = luau_function(bridge, "pointerBinary")
        require_all(
            pointer,
            (
                "noctalia.pluginDataDir()",
                'gsub("/+$", "") .. "/" .. BACKEND_POINTER_NAME',
                "noctalia.fileExists(pointerPath)",
                "readBoundedRegularFile(pointerPath, MAX_BACKEND_POINTER_BYTES)",
                'raw:sub(-1) == "\\n"',
                'raw:find("[\\r\\n]") ~= nil',
                'validatedExecutable(raw, "Backend pointer target")',
            ),
            f"{label} bounded plugin-data backend pointer",
        )

        resolver = luau_function(bridge, "configuredBinary")
        require_all(
            resolver,
            (
                'settingString("backend_binary_path", "")',
                'validatedExecutable(noctalia.expandPath(configured)',
                'return selected, "configured", reason',
                "local pointed, pointerPresent, pointerError = pointerBinary()",
                "if pointerPresent then",
                'return pointed, "pointer", pointerError',
                "noctalia.commandExists(BINARY_NAME)",
                'return BINARY_NAME, "path", ""',
            ),
            f"{label} explicit-pointer-PATH resolver",
        )
        explicit_at = resolver.index('settingString("backend_binary_path", "")')
        pointer_at = resolver.index("pointerBinary()")
        path_at = resolver.index("noctalia.commandExists(BINARY_NAME)")
        assert explicit_at < pointer_at < path_at, (
            f"{label} must resolve backend_binary_path before backend-path before PATH"
        )

    # The retired helper path remains a MotionBGS-only compatibility fallback;
    # it must never become the generic library/palette/Wallhaven backend.
    motion_resolver = luau_function(bridges["MotionBGS compatibility"], "configuredBinary")
    require_all(
        motion_resolver,
        (
            'settingString("motionbgs_binary_path", "")',
            'validatedExecutable(noctalia.expandPath(legacy)',
            'return selected, "legacy-configured", reason',
        ),
        "legacy MotionBGS helper compatibility",
    )
    assert motion_resolver.index("pointerBinary()") < motion_resolver.index(
        'settingString("motionbgs_binary_path", "")'
    ) < motion_resolver.index("noctalia.commandExists(BINARY_NAME)"), (
        "a shared backend pointer must win; legacy MotionBGS is fallback-only before PATH"
    )
    for label in ("generic backend", "Wallhaven"):
        assert "motionbgs_binary_path" not in bridges[label], (
            f"{label} must not adopt the MotionBGS-only migration path"
        )

    palettes = text("palettes.luau")
    palette_client = palettes[
        palettes.index("local function backendSupportsPalettes()") : palettes.index(
            "local function clearInventoryState()"
        )
    ]
    require_all(
        palette_client,
        (
            "noctalia.state.get(BACKEND_STATUS_KEY)",
            "status.available == true",
            'find("," .. BACKEND_CAPABILITY .. ",", 1, true)',
            "noctalia.state.set(BACKEND_PALETTE_COMMAND_KEY, {",
        ),
        "palette inventory inheritance from the generic backend bridge",
    )
    for forbidden in (
        "configuredBinary",
        "pointerBinary",
        "backend_binary_path",
        "motionbgs_binary_path",
        "BINARY_NAME",
        "noctalia.runAsync",
    ):
        assert forbidden not in palette_client, (
            f"palette inventory must not duplicate backend process discovery/launching via {forbidden}"
        )

    generic_launcher = text("scripts/backend-provider")
    motion_launcher = text("scripts/motionbgs-provider")
    require_all(
        generic_launcher,
        ("[[ -f $candidate && ! -L $candidate && -x $candidate ]]",),
        "generic launcher executable boundary",
    )
    require_all(
        motion_launcher,
        (
            "[[ -f $candidate && ! -L $candidate && -x $candidate ]]",
            "binary_subcommand()",
            "unified:probe)",
            "unified:rpc)",
            "legacy:probe)",
            "legacy:rpc)",
        ),
        "MotionBGS unified/legacy executable boundary",
    )

    backend = bridges["generic backend"]
    require_all(
        backend,
        (
            "local DISCOVERY_RETRY_MS = 3000",
            "local nextDiscoveryAtMs = 0",
            "nextDiscoveryAtMs = math.floor(tonumber(noctalia.nowMs()) or 0) + DISCOVERY_RETRY_MS",
            "nextDiscoveryAtMs = 0",
        ),
        "bounded missing-backend rediscovery clock",
    )
    backend_update = luau_function(backend, "update")
    require_all(
        backend_update,
        (
            "noctalia.setUpdateInterval(",
            "not probeBusy",
            "status.available ~= true",
            "status.launcher_available == true",
            "noctalia.nowMs()",
            "nextDiscoveryAtMs",
            "local selected, source = configuredBinary()",
            'status.probe_state == "binary-missing"',
            "selected ~= status.binary_path",
            "source ~= status.binary_source",
            "nextDiscoveryAtMs = now + DISCOVERY_RETRY_MS",
            "startProbe()",
        ),
        "automatic missing-backend rediscovery",
    )
    # Rediscovery is a cheap unresolved-state metadata timer. A compatible
    # backend must not be process-probed forever merely to detect optional
    # pointer replacement, and an unchanged failed candidate is not relaunched.
    assert backend_update.index("status.available ~= true") < backend_update.index("startProbe()")

    for label in ("MotionBGS compatibility", "Wallhaven"):
        bridge = bridges[label]
        require_all(
            bridge,
            (
                'local BACKEND_STATUS_KEY = "wall_in_one_backend_status_v1"',
                "noctalia.state.watch(BACKEND_STATUS_KEY, function(backendState)",
                "backendState.available == true",
                "startProbe(",
            ),
            f"{label} automatic adoption of the rediscovered shared backend",
        )

    panel = text("panel.luau")
    require_all(
        panel,
        (
            "local backendSetupCache =",
            "function panelUi.backendSetupPointerPath()",
            "function panelUi.backendSetupCommands()",
            "function panelUi.backendSetupCard()",
            "4b226a8b2fa8ad41aae1245dcc8e6bfa2bf1c391",
            "https://raw.githubusercontent.com/Go08er/goober-noctalia-plugins-v5/",
            "wall-in-one-backend.sha256",
        ),
        "cached pinned backend setup surface",
    )
    assert panel.count("local backendSetupCache =") == 1, (
        "the setup command block must have one cached construction slot"
    )

    pointer_path = luau_function(panel, "panelUi.backendSetupPointerPath")
    require_all(
        pointer_path,
        ("backendSetupDetails().pointer_path",),
        "exact setup-card backend pointer destination",
    )

    setup_wrapper = luau_function(panel, "panelUi.backendSetupCommands")
    require_all(setup_wrapper, ("backendSetupDetails().commands",), "cached setup-command accessor")
    setup_commands = luau_function(panel, "backendSetupDetails")
    require_all(
        setup_commands,
        (
            "noctalia.pluginDataDir()",
            'gsub("/+$", "")',
            'pluginDataDirectory .. "/backend-path"',
            "backendSetupCache",
            "curl --disable --fail --silent --show-error",
            "--max-redirs 0",
            "--proto '=https'",
            "wall-in-one-backend.sha256",
            "sha256sum -c",
            "chmod 0755",
            "mv -fT --",
            "backend-path",
            "self-test",
            '}, "\\n")',
        ),
        "five-command checksum-first backend setup",
    )
    assert setup_commands.count("--output") == 2, (
        "setup must fetch the pinned payload and sibling checksum as separate data files"
    )
    assert setup_commands.count("mv -fT --") >= 2, (
        "setup must atomically publish both the backend executable and pointer"
    )
    checksum_at = setup_commands.index("sha256sum -c")
    chmod_at = setup_commands.index("chmod 0755")
    pointer_at = setup_commands.rindex("backend-path")
    self_test_at = setup_commands.rindex("self-test")
    assert checksum_at < chmod_at < pointer_at < self_test_at, (
        "setup must verify before chmod, publish the pointer atomically, then self-test"
    )
    command_entries = luau_braced_list_entry_count(setup_commands, "local commands = table.concat({")
    assert command_entries == 5, (
        f"backend setup must expose exactly five nonblank commands, found {command_entries}"
    )

    setup_card = luau_function(panel, "panelUi.backendSetupCard")
    require_all(
        setup_card,
        (
            "panelUi.backendSetupPointerPath()",
            "panelUi.backendSetupCommands()",
            'noctalia.tr("panel.backend_setup.title")',
            'noctalia.tr("panel.backend_setup.pointer_label")',
            'noctalia.tr("panel.backend_setup.command_label")',
            'noctalia.tr("panel.backend_setup.copy")',
            'noctalia.copyToClipboard(commands, "text/plain;charset=utf-8")',
        ),
        "unresolved-backend Home setup card and native copy API",
    )
    assert "noctalia.runAsync" not in setup_card, (
        "the setup card may copy commands but must never execute installer steps"
    )
    home = luau_function(panel, "panelPages.homeSection")
    require_all(
        home,
        (
            "if preview.backendAvailable() then nil else panelUi.backendSetupCard()",
            "{ backendSetupCard, locationCard }",
            "{ backendSetupCard, homeCard }",
        ),
        "unresolved-only setup card in both Home layouts",
    )
    setup_at = home.index("panelUi.backendSetupCard()")
    directory_gate_at = home.index("if not imageReady or not videoReady then")
    assert setup_at < directory_gate_at, (
        "Home must compute/show unresolved backend setup even before media directories are configured"
    )


def test_wallhaven_contract() -> None:
    wallhaven = text("wallhaven.luau")
    require_all(
        wallhaven,
        (
            "local SCHEMA = 1",
            "local RPC_SCHEMA = 1",
            'local COMMAND_KEY = "wall_in_one_wallhaven_command_v1"',
            'local STATUS_KEY = "wall_in_one_wallhaven_status_v1"',
            'local RESULTS_KEY = "wall_in_one_wallhaven_results_v1"',
            'local API_ORIGIN = "https://wallhaven.cc"',
            'local BINARY_NAME = "wall-in-one-backend"',
            'local PROBE_PROTOCOL = "WIO-BACKEND-PROBE1"',
            'local RPC_PROTOCOL = "WIO-BACKEND-RPC1"',
            'local GUARD_CONTENT = "WIO-BACKEND-GUARD1\\n"',
            '["wallhaven.search"] = true',
            '["wallhaven.detail"] = true',
            '["wallhaven.download"] = true',
            '["wallhaven.clear"] = true',
            'settingString("backend_binary_path", "")',
            '"/scripts/backend-provider"',
            'transportDirectory = dataDirectory .. "/wallhaven-bridge-v2/rpc"',
            'install_url = INSTALL_URL',
            "local MAX_RESULTS = 24",
            "local MAX_REQUEST_BYTES = 64 * 1024",
            "local MAX_RESPONSE_BYTES = 128 * 1024",
            "local VALIDATION_BATCH = 4",
            "local DOWNLOAD_OPERATION_BUDGET_MS = 120000",
            "local DOWNLOAD_TIMEOUT_MS = 130000",
            'active_id = ""',
            "local function findResult(id)",
            "detail only accepts an ID from the current Wallhaven results",
            "download only accepts a wallpaper from the current result set",
            "download requires the exact selected Wallhaven media or short URL",
            'status.last_download = download',
            'status.active_id = if type(activeOperation) == "table" and activeOperation.action == "download"',
            "nonce == nil or nonce <= status.last_nonce",
            'action == "search"',
            'action == "detail"',
            'action == "download"',
            'action == "clear"',
            "A Wallhaven operation is already in flight",
            "local function processCompletedTransport()",
            "local function stepValidation()",
            "function update()",
            "noctalia.state.watch(COMMAND_KEY, handleCommand)",
            "handleCommand(noctalia.state.get(COMMAND_KEY))",
        ),
        "thin Wallhaven backend bridge and public state contract",
    )

    probe = wallhaven[
        wallhaven.index("local function probeResult") : wallhaven.index("local function atomicWrite")
    ]
    require_all(
        probe,
        (
            "for capability, _ in pairs(REQUIRED_CAPABILITIES) do",
            '"Wall-in-One backend is missing capability: " .. capability',
            '"exec bash " .. shellQuote(launcherPath) .. " probe " .. shellQuote(binaryCommand)',
            "noctalia.runAsync(command, function(result)",
            "table.insert(completedProbes, { generation = generation, result = result })",
            "local function processCompletedProbe()",
            "local probe, kind, message = probeResult(completed.result)",
        ),
        "generic backend capability probe outside the async callback",
    )

    transport = wallhaven[
        wallhaven.index("local function requestPaths") : wallhaven.index(
            "local function cancelCurrent"
        )
    ]
    require_all(
        transport,
        (
            'transportDirectory .. "/.wall-in-one-backend-wallhaven-key-" .. token',
            'api_key_path = operation.api_key_path or ""',
            'action = "wallhaven." .. operation.action',
            'atomicWrite(operation.api_key_path, "X-API-Key: " .. key .. "\\n", 280)',
            '"chmod 0600 -- " .. shellQuote(operation.api_key_path) .. " && "',
            'shellQuote(operation.request_path)',
            'shellQuote(operation.response_path)',
            'shellQuote(operation.guard_path)',
            "expectedBytes > MAX_RESPONSE_BYTES",
            "readBoundedRegularFile(path, MAX_RESPONSE_BYTES)",
            "local decoded = noctalia.json.decode(raw)",
            "table.insert(completedTransports, { operation = operation, result = result })",
            "local payload, kind, message = launcherTransport(operation, completed.result)",
            "local started, validationKind, validationMessage = beginValidation(operation, payload)",
        ),
        "bounded file RPC with a private credential child and deferred response validation",
    )
    callback = transport[
        transport.index("local started = noctalia.runAsync(command, function(result)") : transport.index(
            "end, timeout)"
        )
    ]
    assert "json.decode" not in callback
    assert "readFile" not in callback
    assert "normalizeWallpaper" not in callback
    launch_command = transport[
        transport.index("local credentialPrefix") : transport.index(
            "local timeout = if operation.action"
        )
    ]
    assert '" .. key' not in launch_command, "Wallhaven API keys must never enter helper argv"

    destination = wallhaven[
        wallhaven.index("local function configuredImageRoot") : wallhaven.index(
            "local function configuredBinary"
        )
    ]
    require_all(
        destination,
        (
            'local configured = settingString("capture_directory", "")',
            'if configured == "" then',
            "local root = noctalia.expandPath(configured)",
            "type(info) == \"table\" and info.isDir == true",
            "local directory = root .. MANAGED_DIRECTORY_SUFFIX",
        ),
        "independently derived existing image root and managed Wallhaven directory",
    )
    assert "noctalia.wallpaperDirectory()" not in destination

    download = wallhaven[
        wallhaven.index("local function validateDownloadResult") : wallhaven.index(
            "local function handleCommand"
        )
    ]
    require_all(
        download,
        (
            "local item = id ~= nil and findResult(id) or nil",
            'local root = configuredImageRoot()',
            'local directory = managedDirectory()',
            'local requiredTarget = directory .. "/wallhaven-" .. id .. "." .. tostring(item.extension or "")',
            'local requiredStaging = requiredTarget .. ".wallhaven-" .. tostring(nonce) .. ".stage"',
            "download refuses to overwrite an existing target or provenance sidecar",
            "path ~= operation.target_path",
            'sidecar ~= path .. ".wallhaven.json"',
            "math.floor(tonumber(info.size) or 0) ~= bytes",
            "status.last_download = download",
        ),
        "coordinator-bound Wallhaven request and installed-result validation",
    )

    for forbidden in (
        "noctalia.http(",
        "noctalia.download(",
        'FETCH_PROTOCOL = "WIO-FETCH1"',
        '"wallhaven-api"',
        '"wallhaven-media"',
        "local function searchUrl",
        "decoded.data",
        "removeManaged",
        "deleteManaged",
        "removeFile(request.target)",
    ):
        assert forbidden not in wallhaven, f"provider must not own deletion policy: {forbidden}"


def test_bounded_fetch_contract() -> None:
    helper_path = ROOT / "scripts" / "bounded-fetch"
    helper = helper_path.read_text(encoding="utf-8")
    require_all(
        helper,
        (
            "readonly protocol='WIO-FETCH1'",
            "wallhaven-api)",
            "palette-catalog)",
            "wallhaven-media)",
            "https://wallhaven\\.cc/api/v1/search",
            "https://api.noctalia.dev/palettes",
            "https://w\\.wallhaven\\.cc/full/",
            "guard_cleanup=$guard",
            "credential_cleanup=$credential",
            "trap cancelled HUP INT TERM",
            "--disable",
            "--connect-timeout 10",
            'ulimit -f "$(((max_bytes + 1023) / 1024))"',
            '  --max-filesize "$max_bytes"',
            "--speed-limit 1024",
            "--speed-time 15",
            "--proto '=https'",
            "--max-redirs 0",
            'curl_arguments+=(--header "@$credential")',
            'ln -- "$body" "$output"',
            "image_signature_allowed",
            "bytes == expected_bytes",
        ),
        "bounded-fetch hard ingress boundary",
    )
    assert "--location" not in helper
    curl_arguments = helper[helper.index("curl_arguments=(") : helper.index("transfer=$(")]
    assert curl_arguments.index("--disable") < curl_arguments.index("--silent")

    self_test = subprocess.run(
        ["bash", str(helper_path), "self-test"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    assert self_test.stdout.strip() == "WIO-FETCH1\tok\tself-test", self_test.stdout

    with tempfile.TemporaryDirectory(prefix="wall-in-one-bounded-fetch-") as temporary:
        root = Path(temporary)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        argv_log = root / "curl.argv"
        fake_curl = fake_bin / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env bash
set -uo pipefail
printf '%s\\0' "$@" >"$FAKE_CURL_ARGV"
output=''
url=''
while (( $# > 0 )); do
  case $1 in
    --output|--url) name=$1; value=$2; shift 2; [[ $name == --output ]] && output=$value || url=$value ;;
    --connect-timeout|--max-time|--max-filesize|--speed-limit|--speed-time|--proto|--proto-redir|--max-redirs|--header|--user-agent|--write-out)
      shift 2 ;;
    --disable|--silent|--show-error|--tlsv1.2) shift ;;
    --request) shift 2 ;;
    *) exit 64 ;;
  esac
done
[[ -n $output && -n $url ]] || exit 64
if [[ $url == *.png ]]; then
  printf '\\211PNG\\r\\n\\032\\nfixture' >"$output"
else
  printf '%s' "${FAKE_BODY:-}" >"$output"
fi
if [[ -n ${FAKE_CANCEL_GUARD:-} ]]; then
  rm -f -- "$FAKE_CANCEL_GUARD"
fi
bytes=$(stat -c '%s' -- "$output")
printf '%s\\t%s\\t%s\\t%s' "${FAKE_STATUS:-200}" "$url" "${FAKE_CONTENT_TYPE:-application/json}" "$bytes"
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment.get('PATH', '')}"
        environment["FAKE_CURL_ARGV"] = str(argv_log)

        secret_value = "offline_private_key_123"
        api_guard = root / ".wall-in-one-guard-wallhaven-test"
        api_secret = root / ".wall-in-one-secret-wallhaven-test"
        api_output = root / "wallhaven.json"
        api_guard.write_text("WIO-FETCH1\n", encoding="utf-8")
        api_secret.write_text(f"X-API-Key: {secret_value}\n", encoding="utf-8")
        environment["FAKE_BODY"] = '{"data":[]}'
        environment["FAKE_CONTENT_TYPE"] = "application/json"
        api_result = subprocess.run(
            [
                "bash",
                str(helper_path),
                "wallhaven-api",
                "https://wallhaven.cc/api/v1/search?q=night&page=1",
                str(api_output),
                str(api_guard),
                str(api_secret),
                "0",
            ],
            check=True,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        api_fields = api_result.stdout.strip().split("\t")
        assert api_fields[:4] == ["WIO-FETCH1", "ok", "wallhaven-api", "200"]
        assert api_fields[-1] == str(api_output)
        assert api_output.read_text(encoding="utf-8") == '{"data":[]}'
        assert not api_guard.exists() and not api_secret.exists()
        curl_argv = argv_log.read_bytes().split(b"\0")
        assert secret_value.encode() not in b"\0".join(curl_argv)
        assert f"@{api_secret}".encode() in curl_argv

        injected_guard = root / ".wall-in-one-guard-wallhaven-injected"
        injected_secret = root / ".wall-in-one-secret-wallhaven-injected"
        injected_output = root / "wallhaven-injected.json"
        injected_guard.write_text("WIO-FETCH1\n", encoding="utf-8")
        injected_secret.write_text(
            f"X-API-Key: {secret_value}\n\nInjected: value\n",
            encoding="utf-8",
        )
        injected = subprocess.run(
            [
                "bash",
                str(helper_path),
                "wallhaven-api",
                "https://wallhaven.cc/api/v1/search?q=night&page=1",
                str(injected_output),
                str(injected_guard),
                str(injected_secret),
                "0",
            ],
            check=False,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        assert injected.returncode != 0
        assert injected.stdout.startswith("WIO-FETCH1\terror\tcredential\t0\t")
        assert not injected_output.exists()
        assert not injected_guard.exists() and not injected_secret.exists()

        media_guard = root / ".wall-in-one-guard-wallhaven-media-test"
        media_output = root / "wallhaven.stage"
        media_guard.write_text("WIO-FETCH1\n", encoding="utf-8")
        environment["FAKE_CONTENT_TYPE"] = "image/png"
        media_bytes = len(b"\x89PNG\r\n\x1a\nfixture")
        media_result = subprocess.run(
            [
                "bash",
                str(helper_path),
                "wallhaven-media",
                "https://w.wallhaven.cc/full/ab/wallhaven-abc123.png",
                str(media_output),
                str(media_guard),
                "-",
                str(media_bytes),
            ],
            check=True,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        assert media_result.stdout.startswith("WIO-FETCH1\tok\twallhaven-media\t200\t")
        assert media_output.read_bytes() == b"\x89PNG\r\n\x1a\nfixture"
        assert not media_guard.exists()

        cancelled_guard = root / ".wall-in-one-guard-palettes-cancel"
        cancelled_output = root / "palettes-cancel.json"
        cancelled_guard.write_text("WIO-FETCH1\n", encoding="utf-8")
        environment["FAKE_BODY"] = "[]"
        environment["FAKE_CONTENT_TYPE"] = "application/json"
        environment["FAKE_CANCEL_GUARD"] = str(cancelled_guard)
        cancelled = subprocess.run(
            [
                "bash",
                str(helper_path),
                "palette-catalog",
                "https://api.noctalia.dev/palettes",
                str(cancelled_output),
                str(cancelled_guard),
                "-",
                "0",
            ],
            check=False,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        assert cancelled.returncode != 0
        assert cancelled.stdout.startswith("WIO-FETCH1\terror\tcancelled\t200\t")
        assert not cancelled_output.exists() and not cancelled_guard.exists()
        assert not list(root.glob(".wall-in-one-fetch-body.*"))


def test_provider_thumbnail_helper_contract() -> None:
    """Pin thumbnail ingress independently of either provider's metadata parser."""

    helper_path = ROOT / "scripts" / "provider-thumbnail"
    helper = helper_path.read_text(encoding="utf-8")
    require_all(
        helper,
        (
            "readonly protocol='WIO-THUMB1'",
            "local wallhaven_re='^https://th\\.wallhaven\\.cc/lg/",
            "local motionbgs_re='^https://motionbgs\\.com/(i/c/",
            '[[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]:0:2}" ]]',
            "readonly max_bytes=$((2 * 1024 * 1024))",
            "readonly max_seconds=30",
            "ulimit -f",
            "--disable",
            "--connect-timeout 10",
            '--max-time "$max_seconds"',
            "--max-filesize",
            "--speed-limit 1024",
            "--speed-time 15",
            "--proto '=https'",
            "--max-redirs 0",
            "image/jpeg",
            "image/png",
            "image/webp",
            '[[ $effective_url == "$url" ]]',
            'signature_type=$(mime_from_file_signature "$body")',
            '[[ $signature_type == "$normalized_type" ]]',
            'validate_image_structure "$body" "$signature_type" "$bytes"',
            "validate_jpeg_structure()",
            "validate_png_structure()",
            "validate_webp_structure()",
            "readonly max_dimension=8192",
            "readonly max_pixels=$((32 * 1024 * 1024))",
            '[[ ! -e $output && ! -L $output ]]',
            'ln -- "$body" "$output"',
            "trap cleanup EXIT",
        ),
        "provider thumbnail hard ingress boundary",
    )
    assert "--location" not in helper, "thumbnail transport must not follow redirects"

    self_test = subprocess.run(
        ["bash", str(helper_path), "self-test"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    assert self_test.stdout.strip() == "WIO-THUMB1\tok\tself-test", self_test.stdout

    with tempfile.TemporaryDirectory(prefix="wall-in-one-provider-thumbnail-") as temporary:
        root = Path(temporary)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        argv_log = root / "curl.argv"
        jpeg_fixture = root / "valid.jpg"
        png_fixture = root / "valid.png"
        webp_fixture = root / "valid.webp"
        jpeg_fixture.write_bytes(
            base64.b64decode(
                "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgG"
                "BgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMD"
                "AwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ"
                "EBAQEBAQEBAQEBAQEBD/wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAA"
                "AAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAHC"
                "f/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ADoDFU3/2Q=="
            )
        )
        png_fixture.write_bytes(
            base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA"
                "+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYk"
                "tHRAH/Ai3eAAAAB3RJTUUH6ggDACswCWe7rgAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAy"
                "Ni0wOC0wM1QwMDo0Mzo0OCswMDowMLJPHRkAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMj"
                "YtMDgtMDNUMDA6NDM6NDgrMDA6MDDDEqWlAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAy"
                "MDI2LTA4LTAzVDAwOjQzOjQ4KzAwOjAwlAeEegAAAApJREFUCNdjYAAAAAIAAeIhvD"
                "MAAAAASUVORK5CYII="
            )
        )
        webp_fixture.write_bytes(
            base64.b64decode(
                "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoBAAEAAgA0JaACdLoB+AADsAD+8MQL/"
                "yC5YXXI1/8gP+QH/ID/+PIAAAA="
            )
        )
        truncated_jpeg = root / "truncated.jpg"
        truncated_png = root / "truncated.png"
        truncated_webp = root / "truncated.webp"
        truncated_jpeg.write_bytes(jpeg_fixture.read_bytes()[:-2])
        truncated_png.write_bytes(png_fixture.read_bytes()[:-6])
        truncated_webp.write_bytes(webp_fixture.read_bytes()[:-1])
        fake_curl = fake_bin / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env bash
set -uo pipefail
printf '%s\\0' "$@" >"$FAKE_CURL_ARGV"
output=''
url=''
while (( $# > 0 )); do
  case $1 in
    --output|--url) name=$1; value=$2; shift 2; [[ $name == --output ]] && output=$value || url=$value ;;
    --connect-timeout|--max-time|--max-filesize|--speed-limit|--speed-time|--proto|--proto-redir|--max-redirs|--header|--user-agent|--write-out)
      shift 2 ;;
    --disable|--silent|--show-error|--tlsv1.2) shift ;;
    --request) shift 2 ;;
    *) exit 64 ;;
  esac
done
[[ -n $output && -n $url ]] || exit 64
case ${FAKE_BODY:-jpeg} in
  jpeg) cp -- "$FAKE_JPEG_FIXTURE" "$output" ;;
  png) cp -- "$FAKE_PNG_FIXTURE" "$output" ;;
  webp) cp -- "$FAKE_WEBP_FIXTURE" "$output" ;;
  truncated-jpeg) cp -- "$FAKE_TRUNCATED_JPEG" "$output" ;;
  truncated-png) cp -- "$FAKE_TRUNCATED_PNG" "$output" ;;
  truncated-webp) cp -- "$FAKE_TRUNCATED_WEBP" "$output" ;;
  bad) printf '<html>not an image</html>' >"$output" ;;
  oversize) cp -- "$FAKE_JPEG_FIXTURE" "$output"; exit 63 ;;
  *) exit 64 ;;
esac
bytes=$(stat -c '%s' -- "$output")
printf '%s\\t%s\\t%s\\t%s' \
  "${FAKE_STATUS:-200}" "${FAKE_EFFECTIVE:-$url}" \
  "${FAKE_CONTENT_TYPE:-image/jpeg}" "${FAKE_REPORTED_BYTES:-$bytes}"
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment.get('PATH', '')}"
        environment["FAKE_CURL_ARGV"] = str(argv_log)
        environment["FAKE_JPEG_FIXTURE"] = str(jpeg_fixture)
        environment["FAKE_PNG_FIXTURE"] = str(png_fixture)
        environment["FAKE_WEBP_FIXTURE"] = str(webp_fixture)
        environment["FAKE_TRUNCATED_JPEG"] = str(truncated_jpeg)
        environment["FAKE_TRUNCATED_PNG"] = str(truncated_png)
        environment["FAKE_TRUNCATED_WEBP"] = str(truncated_webp)

        def fetch(
            provider: str,
            url: str,
            name: str,
            *,
            body: str,
            content_type: str,
            status: int = 200,
            effective: str | None = None,
            reported_bytes: int | None = None,
        ) -> tuple[subprocess.CompletedProcess[str], Path]:
            output = root / name
            invocation_environment = environment.copy()
            invocation_environment["FAKE_BODY"] = body
            invocation_environment["FAKE_CONTENT_TYPE"] = content_type
            invocation_environment["FAKE_STATUS"] = str(status)
            if effective is not None:
                invocation_environment["FAKE_EFFECTIVE"] = effective
            if reported_bytes is not None:
                invocation_environment["FAKE_REPORTED_BYTES"] = str(reported_bytes)
            result = subprocess.run(
                ["bash", str(helper_path), "fetch", provider, url, str(output)],
                check=False,
                env=invocation_environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            return result, output

        jpeg_url = "https://th.wallhaven.cc/lg/ab/abc123.jpg"
        jpeg_result, jpeg_output = fetch(
            "wallhaven",
            jpeg_url,
            "wallhaven.jpg",
            body="jpeg",
            content_type="image/jpeg",
        )
        assert jpeg_result.returncode == 0, (jpeg_result.stdout, jpeg_result.stderr)
        assert jpeg_result.stdout.startswith("WIO-THUMB1\tok\twallhaven\t200\t")
        assert jpeg_output.read_bytes().startswith(b"\xff\xd8\xff")

        webp_url = "https://motionbgs.com/i/c/364x205/media/42/fixture.jpg.webp"
        webp_result, webp_output = fetch(
            "motionbgs",
            webp_url,
            "motion.webp",
            body="webp",
            content_type="image/webp",
        )
        assert webp_result.returncode == 0, (webp_result.stdout, webp_result.stderr)
        assert webp_result.stdout.startswith("WIO-THUMB1\tok\tmotionbgs\t200\t")
        assert webp_output.read_bytes().startswith(b"RIFF")

        png_url = "https://motionbgs.com/media/42/fixture.png"
        png_result, png_output = fetch(
            "motionbgs",
            png_url,
            "motion.png",
            body="png",
            content_type="image/png",
        )
        assert png_result.returncode == 0, (png_result.stdout, png_result.stderr)
        assert png_result.stdout.startswith("WIO-THUMB1\tok\tmotionbgs\t200\t")
        assert png_output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")

        curl_argv = argv_log.read_bytes().split(b"\0")
        assert b"--disable" in curl_argv
        assert b"--max-redirs" in curl_argv
        redirect_index = curl_argv.index(b"--max-redirs")
        assert curl_argv[redirect_index + 1] == b"0"
        max_size_index = curl_argv.index(b"--max-filesize")
        assert curl_argv[max_size_index + 1] == b"2097152"

        conflict_output = root / "existing.jpg"
        conflict_output.write_bytes(b"operator-owned sentinel")
        conflict_result, returned_conflict = fetch(
            "wallhaven",
            jpeg_url,
            conflict_output.name,
            body="jpeg",
            content_type="image/jpeg",
        )
        assert returned_conflict == conflict_output
        assert conflict_result.returncode != 0
        assert conflict_result.stdout.startswith("WIO-THUMB1\terror\tconflict\t")
        assert conflict_output.read_bytes() == b"operator-owned sentinel"

        invalid_cases = (
            (
                "wallhaven",
                "https://th.wallhaven.cc.evil.invalid/lg/ab/abc123.jpg",
                "cross-origin.jpg",
                "jpeg",
                "image/jpeg",
                200,
                None,
                None,
            ),
            (
                "wallhaven",
                jpeg_url,
                "redirect.jpg",
                "jpeg",
                "image/jpeg",
                302,
                "https://evil.invalid/redirect.jpg",
                None,
            ),
            (
                "wallhaven",
                jpeg_url,
                "wrong-mime.jpg",
                "jpeg",
                "text/html",
                200,
                None,
                None,
            ),
            (
                "wallhaven",
                jpeg_url,
                "wrong-signature.jpg",
                "bad",
                "image/jpeg",
                200,
                None,
                None,
            ),
            (
                "motionbgs",
                webp_url,
                "oversize.webp",
                "oversize",
                "image/webp",
                200,
                None,
                None,
            ),
            (
                "wallhaven",
                jpeg_url,
                "truncated-result.jpg",
                "truncated-jpeg",
                "image/jpeg",
                200,
                None,
                None,
            ),
            (
                "motionbgs",
                png_url,
                "truncated-result.png",
                "truncated-png",
                "image/png",
                200,
                None,
                None,
            ),
            (
                "motionbgs",
                webp_url,
                "truncated-result.webp",
                "truncated-webp",
                "image/webp",
                200,
                None,
                None,
            ),
        )
        for case in invalid_cases:
            result, output = fetch(
                case[0],
                case[1],
                case[2],
                body=case[3],
                content_type=case[4],
                status=case[5],
                effective=case[6],
                reported_bytes=case[7],
            )
            assert result.returncode != 0, (case[2], result.stdout, result.stderr)
            assert result.stdout.startswith("WIO-THUMB1\terror\t"), (case[2], result.stdout)
            assert not output.exists(), f"rejected thumbnail was installed: {case[2]}"

        assert not list(root.glob(".wall-in-one-thumbnail.*")), "thumbnail helper leaked a temporary"


def test_provider_preview_panel_contract() -> None:
    """Pin the thin preview.sync bridge and its update-only scheduler."""

    panel = text("panel.luau")
    vm = (ROOT.parent / "tests" / "vm" / "wall-in-one.nix").read_text(encoding="utf-8")
    preview_block = panel[
        panel.index("local preview = {}") : panel.index("local function resetLibraryVisibility")
    ]
    require_all(
        preview_block,
        (
            'local BACKEND_STATUS_KEY = "wall_in_one_backend_status_v1"',
            'local RPC_ACTION = "preview.sync"',
            'local RPC_PROTOCOL = "WIO-BACKEND-RPC1"',
            'local GUARD_CONTENT = "WIO-BACKEND-GUARD1\\n"',
            "local MAX_REQUEST_BYTES = 64 * 1024",
            "local MAX_RESPONSE_BYTES = 128 * 1024",
            "local MAX_ITEMS = 13",
            "local PAGE_ITEMS = 12",
            "local RPC_TIMEOUT_MS = 55000",
            "local function responsePayload(operation, result)",
            "local function applyResponse(operation, payload)",
            "local function launchPlan(plan)",
            "local function buildPlan(provider, scope, items, first, last, selected, enabled)",
            "local function step()",
            "preview.plan = plan",
            "preview.node = node",
            "preview.step = step",
            "preview.setBackendStatus = function(nextStatus)",
        ),
        "thin provider-preview backend bridge",
    )

    # Manifest/LRU/fetch ownership is in Python. The panel names the bundled
    # helper once as request data, but never invokes it itself.
    for retired in (
        "PREVIEW_CACHE_SCHEMA",
        "PREVIEW_MAX_CACHE_BYTES",
        "PREVIEW_MAX_ENTRIES",
        "PREVIEW_MAX_CONCURRENT",
        "PREVIEW_MAX_QUEUE",
        "previewManifestPath",
        "savePreviewManifest",
        "prunePreviewCache",
        "initializePreviewCache",
        "stepPreviewInitialization",
        "startOnePreviewTask",
        "previewHelperResult",
        "WIO-THUMB1",
        '"/manifest.json"',
        "noctalia.listDir(",
    ):
        assert retired not in preview_block, f"in-panel preview machinery remains: {retired!r}"
    assert preview_block.count('"/scripts/provider-thumbnail"') == 1
    assert preview_block.count("noctalia.runAsync(") == 1
    assert "shellQuote(thumbnailHelperPath)" not in preview_block

    storage = preview_block[
        preview_block.index("local function initializeStorage()") : preview_block.index(
            "local function atomicWrite"
        )
    ]
    require_all(
        storage,
        (
            "local pluginDirectory = noctalia.pluginDir()",
            "local dataDirectory = noctalia.pluginDataDir()",
            'launcherPath = pluginDirectory .. "/scripts/backend-provider"',
            'thumbnailHelperPath = pluginDirectory .. "/scripts/provider-thumbnail"',
            'cacheDirectory = dataDirectory .. "/provider-previews/v1"',
            'rpcDirectory = cacheDirectory .. "/rpc"',
            "noctalia.mkdirAll(rpcDirectory)",
        ),
        "stable v1 preview transport",
    )

    launch = preview_block[
        preview_block.index("local function launchPlan(plan)") : preview_block.index(
            "local function buildPlan"
        )
    ]
    require_all(
        launch,
        (
            "plan.generation ~= generation",
            "#plan.items < 1",
            "not initializeStorage() or not backendAvailable()",
            'request_path = rpcDirectory .. "/request-" .. token .. ".json"',
            'response_path = rpcDirectory .. "/response-" .. token .. ".json"',
            'guard_path = rpcDirectory .. "/.wall-in-one-backend-guard-" .. token',
            "transport_directory = rpcDirectory",
            "guard_path = operation.guard_path",
            "operation_timeout_ms = math.min(45000, RPC_TIMEOUT_MS - 5000)",
            "thumbnail_helper = thumbnailHelperPath",
            "table.insert(payload.items, { provider = item.provider, id = item.id, url = item.url })",
            "not atomicWrite(operation.guard_path, GUARD_CONTENT, #GUARD_CONTENT)",
            "not atomicWrite(operation.request_path, encoded .. \"\\n\", MAX_REQUEST_BYTES)",
            '"exec bash "',
            "shellQuote(launcherPath)",
            '" rpc "',
            "shellQuote(safeBinary(backendStatus))",
            "shellQuote(operation.request_path)",
            "shellQuote(operation.response_path)",
            "shellQuote(operation.guard_path)",
        ),
        "exact nonce-bound preview.sync launch",
    )
    payload_start = launch.index("local payload = {")
    payload_end = launch.index("    for _, item in ipairs(operation.items)", payload_start)
    payload = launch[payload_start:payload_end]
    assert set(re.findall(r"^        ([a-z_]+) =", payload, flags=re.MULTILINE)) == {
        "schema",
        "action",
        "request_id",
        "transport_directory",
        "guard_path",
        "operation_timeout_ms",
        "thumbnail_helper",
        "items",
    }

    callback_match = re.search(
        r"noctalia\.runAsync\(command, function\(result\)\n(.*?)\n    end, RPC_TIMEOUT_MS\)",
        launch,
        flags=re.DOTALL,
    )
    assert callback_match is not None
    callback = callback_match.group(1)
    require_all(
        callback,
        ("completedOperation = { operation = operation, result = result }", "wakeUpdate()"),
        "constant-work preview callback",
    )
    for forbidden in (
        "noctalia.json.",
        "noctalia.readFile(",
        "noctalia.fileInfo(",
        "noctalia.removeFile(",
        "render()",
        "panelPages.renderNow()",
        "for ",
        "while ",
    ):
        assert forbidden not in callback, f"preview callback is not O(1): {forbidden!r}"

    response = preview_block[
        preview_block.index("local function responsePayload") : preview_block.index(
            "local function applyResponse"
        )
    ]
    require_all(
        response,
        (
            "result.timedOut == true",
            "wire ~= RPC_PROTOCOL",
            "requestId ~= operation.request_id",
            "responsePath ~= operation.response_path",
            "bytes > MAX_RESPONSE_BYTES",
            "math.floor(tonumber(info.size) or 0) ~= bytes",
            "local raw = noctalia.readFile(responsePath)",
            "tonumber(decoded.schema) ~= RPC_SCHEMA",
            "decoded.action ~= RPC_ACTION",
            "decoded.request_id ~= operation.request_id",
            "decoded.ok ~= true",
            '#decoded.items ~= #operation.items',
        ),
        "bounded nonce/action response gate",
    )
    adoption = preview_block[
        preview_block.index("local function applyResponse") : preview_block.index(
            "local function finishCompletion"
        )
    ]
    require_all(
        adoption,
        (
            "nextPending ~= math.floor(nextPending)",
            "nextPending > #operation.items",
            "local seen = {}",
            "for _, result in ipairs(payload.items) do",
            "index ~= math.floor(index)",
            "index > #operation.items",
            "or seen[index]",
            "seen[index] = true",
            "local requested = operation.items[index]",
            'state ~= "ready" and state ~= "pending" and state ~= "error"',
            "not ownedFilename(requested.provider, requested.id, filename)",
            'path = cacheDirectory .. "/" .. filename',
            "not directChild(path, cacheDirectory)",
            "countedPending ~= nextPending",
            "previewRecords = nextRecords",
            "previewPaths = nextPaths",
        ),
        "ordinal/state/filename response validation",
    )
    assert adoption.index("for _, result in ipairs(payload.items) do") < adoption.index(
        "previewRecords = nextRecords"
    )
    assert re.search(r"^\s*while\b", adoption, flags=re.MULTILINE) is None

    filename_gate = preview_block[
        preview_block.index("local function ownedFilename") : preview_block.index(
            "local function backendHasCapability"
        )
    ]
    require_all(
        filename_gate,
        (
            'value:find("[/\\\\%c]")',
            '"^(wallhaven)%-([a-z0-9]+)%-([0-9]+)%-([0-9]+)%.([a-z]+)$"',
            '"^(motionbgs)%-([a-z0-9][a-z0-9-]*)%-([0-9]+)%-([0-9]+)%.([a-z]+)$"',
            "fileProvider == provider",
            "fileId == itemId",
            'extension == "jpg"',
            'extension == "png"',
            'extension == "webp"',
        ),
        "owned preview filename gate",
    )

    plan = preview_block[
        preview_block.index("local function buildPlan") : preview_block.index("local function node")
    ]
    require_all(
        plan,
        (
            "startIndex + PAGE_ITEMS - 1",
            "#requests >= MAX_ITEMS",
            "seen[candidate.key] = true",
            "for index = startIndex, endIndex do",
            "append(itemFields(provider, items[index]))",
            "append(selectedFields(provider, selected))",
            "pendingPlan = if currentPlan.enabled and #requests > 0 then currentPlan else nil",
            "currentPlan.source == source",
            "currentPlan.selected == selected",
        ),
        "12-card plus selected-item generation plan",
    )
    assert re.search(r"^\s*while\b", plan, flags=re.MULTILINE) is None

    node = preview_block[
        preview_block.index("local function node(provider") : preview_block.index(
            "local function cancel()"
        )
    ]
    require_all(
        node,
        ("local path = previewPaths[key]", "return ui.image({", "path = path", "return ui.box({"),
        "constant-time local preview tile",
    )
    for forbidden in (
        "http://",
        "https://",
        "thumbnail_url",
        "poster_url",
        "thumbs",
        "noctalia.fileExists(",
        "noctalia.fileInfo(",
        "noctalia.runAsync(",
    ):
        assert forbidden not in node

    step = preview_block[
        preview_block.index("local function step()") : preview_block.index("preview.plan = plan")
    ]
    require_all(
        step,
        (
            "cancelRequested and activeOperation ~= nil",
            "completedOperation ~= nil",
            "local changed = finishCompletion()",
            'not storageInitialized and type(pendingPlan) == "table"',
            "local nextPlan = pendingPlan",
            "pendingPlan = nil",
            "return launchPlan(nextPlan), false",
        ),
        "one-operation update scheduler",
    )
    assert re.search(r"^\s*while\b", step, flags=re.MULTILINE) is None

    provider_items = panel[
        panel.index("function panelUi.providerItems(value, page, pageSize)") : panel.index(
            "panelUi.providerInstallCache"
        )
    ]
    require_all(
        provider_items,
        (
            "local total = math.min(#source, 48)",
            "local pages = math.max(1, math.ceil(total / size))",
            "local first = (current - 1) * size + 1",
            "local last = math.min(total, first + size - 1)",
            "for index = first, last do",
        ),
        "12-card provider paging",
    )
    chunk = re.search(r"local PROVIDER_RESULT_CHUNK = ([0-9]+)", panel)
    assert chunk is not None and int(chunk.group(1)) == 12
    assert [((page - 1) * 12 + 1, min(36, page * 12)) for page in range(1, 4)] == [
        (1, 12),
        (13, 24),
        (25, 36),
    ]

    wallhaven_section = panel[
        panel.index("local function wallhavenSection") : panel.index("local function motionBgsSection")
    ]
    motionbgs_section = panel[
        panel.index("local function motionBgsSection") : panel.index("local function librarySection")
    ]
    for source, provider, readiness in (
        (wallhaven_section, "wallhaven", "ready"),
        (motionbgs_section, "motionbgs", "integrationReady"),
    ):
        require_all(
            source,
            (
                'local sourceItems = type(results.items) == "table" and results.items or {}',
                "local items, itemCount, localPage, firstItem, lastItem = panelUi.providerItems(",
                f"providerResultPages.{provider}",
                "PROVIDER_RESULT_CHUNK",
                "preview.plan(",
                f'"{provider}"',
                "sourceItems,",
                "firstItem,",
                "lastItem,",
                readiness,
                f'preview.node("{provider}"',
                "panelUi.appendPageControls(",
            ),
            f"paged {provider} preview wiring",
        )
        assert source.count("preview.plan(") == 1
        assert source.count("preview.node(") == 1
        assert "preview.ensure(" not in source

    require_all(
        vm,
        (
            "for index = 1, 36 do",
            '"items=36 visible=12"',
            "vm-motion-sustained-start",
            "vm-motion-sustained-probe",
            "exceeded its CPU budget",
            "disabled after repeated timeouts",
        ),
        "36-result sustained-frame VM regression",
    )

    update_callback = panel[
        panel.index("function update()") : panel.index("function onFrameTick(_deltaMs)")
    ]
    require_all(
        update_callback,
        (
            "preview.refreshClock()",
            "preview.retry()",
            "local _, redraw = preview.step()",
            "preview.requestRender()",
            "if preview.takeRender() then",
            "panelPages.renderNow()",
        ),
        "update-only preview completion and full render",
    )
    assert update_callback.index("preview.step()") < update_callback.index("panelPages.renderNow()")

    frame_callback = panel[
        panel.index("function onFrameTick(_deltaMs)") : panel.index("function onIpc")
    ]
    require_all(
        frame_callback,
        (
            "if isOpen and dragTokensDirty then",
            "if stepDragTokenReconciliation() then",
            "local stillChoiceWork = isOpen",
            "panelUi.pairingStillChoiceWork()",
            "if stillChoiceWork and panelUi.stepPairingStillChoiceReconciliation() then",
            "render()",
            "panelUi.workshopIndexWork()",
            "panelUi.stepWorkshopIndexReconciliation()",
            "paletteEntryIndexWork()",
            "stepPaletteEntryIndexReconciliation()",
            "preview.settle(isOpen and (dragTokensDirty or stillChoiceWork or workshopIndexWork or paletteIndexWork))",
        ),
        "bounded presentation-data frame callback",
    )
    for forbidden in (
        "preview.step()",
        "preview.takeRender()",
        "panelPages.renderNow()",
        "noctalia.runAsync(",
        "noctalia.json.",
        "noctalia.readFile(",
    ):
        assert forbidden not in frame_callback
    assert re.search(r"^\s*update\(\)\s*$", frame_callback, flags=re.MULTILINE) is None
    render_now_calls = list(re.finditer(r"(?<!function )panelPages\.renderNow\(\)", panel))
    assert len(render_now_calls) == 1
    assert panel.index("function update()") < render_now_calls[0].start() < panel.index(
        "function onFrameTick(_deltaMs)"
    )

    navigation = panel[
        panel.index("function panelPages.selectShopPage") : panel.index(
            "function panelPages.selectPlaylistPage"
        )
    ]
    require_all(
        navigation,
        (
            "if not panelPages.validShopSubpages[subpage] then",
            'if activePage == "shops" and activeSubpage == subpage then',
            "preview.cancel()",
            'activePage = "shops"',
            "activeSubpage = subpage",
            "render()",
        ),
        "constant-time deferred shop navigation",
    )
    for forbidden in (
        "panelPages.renderNow()",
        "wallhavenSection(",
        "motionBgsSection(",
        "preview.step()",
        "noctalia.runAsync(",
    ):
        assert forbidden not in navigation

    assert "preview.initializeScheduler()" in panel
    assert "preview.setBackendStatus(noctalia.state.get(preview.backendStatusKey))" in panel
    require_all(
        panel,
        (
            "noctalia.state.watch(preview.backendStatusKey, function(nextState)",
            "preview.setBackendStatus(nextState)",
        ),
        "backend availability watcher",
    )
    for image_call in re.findall(r"ui\.image\(\{(.*?)\}\)", panel, flags=re.DOTALL):
        assert "http://" not in image_call and "https://" not in image_call
        assert "thumbnail_url" not in image_call and "poster_url" not in image_call


def test_renderer_static_contract() -> None:
    renderer = text("renderer.luau")
    supervisor = text("scripts/renderer-supervisor")
    require_all(
        renderer,
        (
            "local SCHEMA = 1",
            'local COMMAND_KEY = "wall_in_one_renderer_command_v1"',
            'local STATUS_KEY = "wall_in_one_renderer_status_v1"',
            "local MAX_QUEUE = 64",
            "local MAX_COMMAND_BYTES = 4096",
            "local FIFO_WRITE_TIMEOUT_MS = 5000",
            "local INSTANCE_ID =",
            'runtime:gsub("/+$", "") .. "/noctalia-wall-in-one"',
            'dataDirectory:gsub("/+$", "") .. "/runtime"',
            '"exec bash " .. shellQuote(helper)',
            "noctalia.runStream(command, handleSupervisorLine)",
            "for _, output in ipairs(noctalia.outputs())",
            'if id:match("^%d+$") == nil or #id > 24',
            'autoPauseMode ~= "FULL" and autoPauseMode ~= "MAX" and autoPauseMode ~= "ACTIVE"',
            "noctalia.fileInfo(video)",
            "local function validatedProjectDirectory(value)",
            'command.project_directory or command.project_path or ""',
            'source = if projectDirectory ~= "" then projectDirectory else id',
            "local INTERNAL_LAYERS = {",
            "local pendingCommandMetadata = {}",
            "local activeWrite = nil",
            "instance_id = INSTANCE_ID",
            "status_revision = 0",
            "status.status_revision = if revision >= MAX_NONCE then 1 else math.floor(revision) + 1",
            "local function releaseActiveWrite(item)",
            "activeWrite ~= item",
            "local function acknowledgeWriteThrough(nonce)",
            "acknowledgeWriteThrough(event.nonce)",
            "local acknowledgedWrite = acknowledgeWriteThrough(event.nonce)",
            "elseif acknowledgedWrite then",
            "item.started_at_ms = noctalia.nowMs()",
            "noctalia.nowMs() - tonumber(item.started_at_ms) > FIFO_WRITE_TIMEOUT_MS",
            '"write-timeout"',
            "local function validatedWEngineOptions(command)",
            "not INTERNAL_LAYERS[layer]",
            '"WIO1"',
            '"start_w_engine"',
            "local function encodeWEngineCapture(command, nonce, output)",
            '"capture_w_engine"',
            'event.event == "capture-started"',
            'event.event == "captured"',
            'event.event == "capture-error"',
            'event.event == "cancelled"',
            'stagingName:match("^capture%-%w[%w%-]*%.png$")',
            'workshop_id = type(metadata) == "table" and metadata.workshop_id or nil',
            'source = type(metadata) == "table" and metadata.source or nil',
            'muted = type(metadata) == "table" and metadata.muted or nil',
            'volume = type(metadata) == "table" and metadata.volume or nil',
            'event.event == "volume-set"',
            'event.event == "unsupported"',
            'event.event == "control-error"',
            'layer = type(metadata) == "table" and metadata.layer or nil',
            '"start_mpvpaper"',
            "noctalia.state.watch(COMMAND_KEY",
            "handleCommand(noctalia.state.get(COMMAND_KEY))",
            "function onConfigChanged()",
            "dd conv=nocreat,notrunc oflag=nofollow",
        ),
        "renderer service",
    )
    # A single cancellable stream owns the supervisor.  Cleanup must stay in
    # that process tree instead of launching an uncancellable teardown job.
    assert renderer.count("noctalia.runStream(") == 1
    assert "local writeInFlight" not in renderer
    async_success = renderer[
        renderer.index("local accepted = noctalia.runAsync") : renderer.index("if not accepted and releaseActiveWrite")
    ]
    assert async_success.index("pumpQueue()") < async_success.index("publishStatus()")
    assert "function onExit" not in renderer or "noctalia.runAsync" not in renderer[renderer.index("function onExit") :]
    supervisor_failure = renderer[
        renderer.index("local function markSupervisorUnavailable") : renderer.index("local function shellQuote")
    ]
    require_all(
        supervisor_failure,
        ("pendingLines = {}", "pendingCommandMetadata = {}", "activeWrite = nil"),
        "renderer supervisor failure queue cleanup",
    )

    require_all(
        supervisor,
        (
            "mkfifo -m 600",
            'exec 3<>"$fifo_path"',
            "declare -A child_pid=()",
            "declare -A child_pause_mode=()",
            "declare -A child_muted=()",
            "declare -A child_artifact=()",
            "declare -A child_artifact_nonce=()",
            "safe_output_name()",
            'value=${value//:/%3A}',
            "artifact_open_by_child()",
            '[[ -d /proc/$pid/fd ]] || return 1',
            'for descriptor in /proc/"$pid"/fd/*; do',
            '[[ ! $descriptor -ef $artifact ]] || return 0',
            'if (( stable >= 1 )) && ! artifact_open_by_child "$pid" "$artifact"; then',
            'local pid=${child_pid[$output]:-}',
            'kill -TERM "$pid"',
            'kill -KILL "$pid"',
            'kill -STOP "$pid"',
            'kill -CONT "$pid"',
            'wait "$pid"',
            'rm -f -- "$fifo_path"',
            "trap cleanup EXIT",
            '--layer "$layer"',
            'case $layer in background|bottom)',
            'args+=(--screenshot "$screenshot_path" --screenshot-delay "$screenshot_delay")',
            "finish_capture()",
            "fail_capture()",
            "check_captures()",
            'emit "$nonce" captured',
            'emit "$nonce" capture-error',
            'emit "$artifact_nonce" cancelled',
            'rm -f -- "$artifact"',
            'local options="loop-file=inf panscan=1.0 terminal=no volume=$volume"',
            'options+=\' mute=yes\'',
            'args+=(--auto-pause)',
            'args+=(--auto-mode "$auto_pause_mode")',
            "socket_client_available()",
            "socket_command()",
            "playback_output()",
            "audio_output()",
            'emit "$nonce" unsupported',
            'emit "$nonce" control-error',
            'emit "$nonce" volume-set',
            'options+=" $extra_options"',
            "10#$nonce <= last_nonce",
            "start_w_engine has invalid fields",
            "capture_w_engine has invalid fields",
            "start_mpvpaper has invalid fields",
        ),
        "renderer supervisor",
    )
    assert "child_source" not in supervisor
    assert "child_volume" not in supervisor
    executable_supervisor = "\n".join(
        line for line in supervisor.splitlines() if not line.lstrip().startswith("#")
    )
    for forbidden in ("pgrep", "pkill", "killall", "setsid", "systemd-run"):
        assert forbidden not in executable_supervisor, (
            f"renderer supervisor uses name/detached ownership: {forbidden}"
        )
    assert 'value=${value//:/_}' not in supervisor


def test_capture_helper_fallback_validation() -> None:
    """Exercise signature-only validation with FFmpeg deliberately absent."""

    helper = ROOT / "scripts" / "capture-still"
    bash = shutil.which("bash")
    assert bash is not None
    with tempfile.TemporaryDirectory(prefix="wall-in-one-image-gate-") as temporary:
        temp = Path(temporary)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        for command in ("cp", "mkdir", "mktemp", "mv", "od", "rm", "stat", "tail", "tr"):
            executable = shutil.which(command)
            assert executable is not None, f"required test utility is missing: {command}"
            (bin_dir / command).symlink_to(executable)

        # Both payloads have the short magic accepted by the old gate. The
        # WebP declares an impossible VP8 chunk; AVIF cannot be established
        # safely from its ftyp box alone when no decoder is available.
        malformed = {
            "truncated.webp": b"RIFF\x0c\x00\x00\x00WEBPVP8 \xe8\x03\x00\x00",
            "header-only.avif": b"\x00\x00\x00\x18ftypavif" + (b"\x00" * 12),
        }
        environment = os.environ.copy()
        environment["PATH"] = str(bin_dir)
        for name, payload in malformed.items():
            source = temp / name
            destination = temp / f"accepted-{name}"
            source.write_bytes(payload)
            result = subprocess.run(
                [bash, str(helper), "copy", str(source), str(destination)],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )
            assert result.returncode == 65, (name, result.returncode, result.stderr)
            assert not destination.exists(), f"malformed image was promoted: {name}"
            assert not list(temp.glob(".*.part")), f"malformed image leaked a temporary: {name}"


def _write_fake_renderer(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env bash
set -u
name=${0##*/}
if [[ ${1:-} == --help ]]; then
  case $name in
    linux-wallpaperengine) printf '%s\n' '  --layer <background|bottom>' ;;
    mpvpaper) printf '%s\n' '  --auto-pause  --auto-mode <FULL|MAX|ACTIVE>' ;;
  esac
  exit 0
fi
screenshot=
socket=
want_screenshot_path=0
for argument in "$@"; do
  if (( want_screenshot_path == 1 )); then
    screenshot=$argument
    break
  fi
  [[ $argument != --screenshot ]] || want_screenshot_path=1
  if [[ $argument == *input-ipc-server=* ]]; then
    socket=${argument#*input-ipc-server=}
    socket=${socket%% *}
  fi
done
case ${0##*/} in
  linux-wallpaperengine)
    if [[ -n $screenshot ]]; then
      log=${WIO_ENGINE_CAPTURE_LOG:?}
      printf '%s\n' "$$" >"${WIO_ENGINE_CAPTURE_PID:?}"
    else
      log=${WIO_ENGINE_LOG:?}
    fi
    ;;
  mpvpaper) log=${WIO_MPV_LOG:?} ;;
  *) exit 64 ;;
esac
{
  printf '%s\\0' "$$"
  printf '%s\\0' "$@"
} >"$log"

ipc_pid=
if [[ $name == mpvpaper && -n $socket ]]; then
  python3 - "$socket" "${WIO_MPV_SOCKET_MODE:?}" <<'PY' &
import errno
import os
from pathlib import Path
import socket
import stat
import sys
import time

socket_path, mode_path = sys.argv[1:]
server = socket.socket(socket.AF_UNIX)
mode = "bound"
try:
    server.bind(socket_path)
    server.listen(1)
except PermissionError as error:
    if error.errno != errno.EPERM:
        raise
    # Some container sandboxes permit AF_UNIX clients but prohibit bind().
    # The fake socat below never connects; it only needs an existing socket
    # inode so the production supervisor exercises its guarded IPC branch.
    # Reuse a real host socket only for that constrained test-fixture case.
    candidates = (
        os.environ.get("WIO_MPV_SOCKET_FALLBACK", ""),
        f"/run/user/{os.getuid()}/bus",
        "/nix/var/nix/daemon-socket/socket",
    )
    fallback = next(
        (
            candidate
            for candidate in candidates
            if candidate and os.path.exists(candidate) and stat.S_ISSOCK(os.stat(candidate).st_mode)
        ),
        "",
    )
    if not fallback:
        raise
    server.close()
    os.symlink(fallback, socket_path)
    mode = "restricted-sandbox-symlink"
Path(mode_path).write_text(mode, encoding="utf-8")
time.sleep(120)
PY
  ipc_pid=$!
fi

cleanup_fake() {
  if [[ -n $ipc_pid ]]; then
    kill "$ipc_pid" 2>/dev/null || true
    wait "$ipc_pid" 2>/dev/null || true
  fi
  [[ -z $socket ]] || rm -f -- "$socket"
  exit 0
}
trap cleanup_fake TERM INT HUP

if [[ $name == linux-wallpaperengine && -n $screenshot ]]; then
  mode=$(<"${WIO_ENGINE_CAPTURE_MODE:?}")
  case $mode in
    success)
      # Hold the output inode open after a stable partial write. The
      # supervisor must not mistake size stability for capture completion.
      exec 9>"$screenshot"
      head -c 8 -- "${WIO_ENGINE_SCREENSHOT_SOURCE:?}" >&9
      sleep 2.2
      tail -c +9 -- "${WIO_ENGINE_SCREENSHOT_SOURCE:?}" >&9
      exec 9>&-
      ;;
    block)
      : >"$screenshot"
      while :; do
        printf x >>"$screenshot"
        sleep 0.1
      done
      ;;
    *) exit 64 ;;
  esac
fi
while :; do sleep 0.1; done
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _write_fake_socat(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env bash
set -u
IFS= read -r command_text || true
printf '%s\n' "$command_text" >>"${WIO_MPV_CONTROL_LOG:?}"
printf '%s\n' '{ "error": "success" }'
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError as error:
        return error.errno == errno.EPERM
    return True


def _wait_until(predicate, message: str, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError(message)


def _nul_fields(path: Path) -> list[str]:
    data = path.read_bytes().split(b"\0")
    if data and data[-1] == b"":
        data.pop()
    return [field.decode("utf-8") for field in data]


def test_renderer_supervisor() -> None:
    helper = ROOT / "scripts" / "renderer-supervisor"
    with tempfile.TemporaryDirectory(prefix="wall-in-one-renderer-test-") as temporary:
        temp = Path(temporary)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        for name in ("linux-wallpaperengine", "mpvpaper"):
            _write_fake_renderer(bin_dir / name)
        _write_fake_socat(bin_dir / "socat")
        video = temp / "fixture video.mp4"
        video.write_bytes(b"fixture")
        workshop_project = temp / "custom workshop" / "431960001"
        workshop_project.mkdir(parents=True)
        (workshop_project / "project.json").write_text('{"title":"fixture"}', encoding="utf-8")
        engine_log = temp / "engine.args"
        capture_log = temp / "capture.args"
        capture_pid_file = temp / "capture.pid"
        capture_mode = temp / "capture.mode"
        capture_mode.write_text("success", encoding="utf-8")
        screenshot_source = temp / "fixture screenshot.png"
        screenshot_source.write_bytes(b"\x89PNG\r\n\x1a\nwall-in-one-fixture")
        captured_artifact = temp / "capture success.png"
        cancelled_artifact = temp / "capture cancelled.png"
        mpv_log = temp / "mpv.args"
        mpv_control_log = temp / "mpv.controls"
        mpv_socket_mode = temp / "mpv.socket-mode"
        fifo = temp / "runtime" / "commands.fifo"
        environment = os.environ.copy()
        environment.update(
            PATH=f"{bin_dir}:{environment.get('PATH', '')}",
            WIO_ENGINE_LOG=str(engine_log),
            WIO_ENGINE_CAPTURE_LOG=str(capture_log),
            WIO_ENGINE_CAPTURE_PID=str(capture_pid_file),
            WIO_ENGINE_CAPTURE_MODE=str(capture_mode),
            WIO_ENGINE_SCREENSHOT_SOURCE=str(screenshot_source),
            WIO_MPV_LOG=str(mpv_log),
            WIO_MPV_CONTROL_LOG=str(mpv_control_log),
            WIO_MPV_SOCKET_MODE=str(mpv_socket_mode),
        )
        sentinel = subprocess.Popen(["sleep", "60"])
        supervisor = subprocess.Popen(
            ["bash", str(helper), str(fifo)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )

        def event(wanted: str, nonce: int | None = None, timeout: float = 6.0) -> list[str]:
            assert supervisor.stdout is not None
            deadline = time.monotonic() + timeout
            observed: list[str] = []
            while time.monotonic() < deadline:
                ready, _, _ = select.select([supervisor.stdout], [], [], 0.2)
                if not ready:
                    continue
                line = supervisor.stdout.readline().rstrip("\n")
                if not line:
                    continue
                fields = line.split("\t", 6)
                observed.append(line)
                if len(fields) == 7 and fields[0] == "WIO1" and fields[2] == wanted:
                    if nonce is None or int(fields[1]) == nonce:
                        return fields
            raise AssertionError(f"missing renderer event {wanted}/{nonce}; observed={observed}")

        def send(fields: list[object]) -> None:
            _wait_until(fifo.exists, "renderer FIFO was not created")
            with fifo.open("w", encoding="utf-8") as stream:
                stream.write("\t".join(map(str, fields)) + "\n")

        engine_pid = 0
        capture_pid = 0
        cancelled_pid = 0
        mpv_pid = 0
        coexist_mpv_pid = 0
        collision_colon_pid = 0
        collision_underscore_pid = 0
        try:
            event("ready", 0)
            assert stat.S_IMODE(fifo.stat().st_mode) == 0o600

            send(
                [
                    "WIO1",
                    1,
                    "start_w_engine",
                    "HEADLESS-1",
                    workshop_project,
                    60,
                    15,
                    "fill",
                    "border",
                    "background",
                    0,
                    1,
                    1,
                    1,
                    1,
                    1,
                    0,
                    1,
                ]
            )
            event("started", 1)
            _wait_until(engine_log.exists, "fake Wallpaper Engine was not launched")
            engine_args = _nul_fields(engine_log)
            engine_pid = int(engine_args[0])
            assert _alive(engine_pid)
            assert engine_args[1:] == [
                "--screen-root",
                "HEADLESS-1",
                "--bg",
                str(workshop_project),
                "--scaling",
                "fill",
                "--clamp",
                "border",
                "--fps",
                "60",
                "--layer",
                "background",
                "--volume",
                "15",
                "--noautomute",
                "--no-audio-processing",
                "--disable-particles",
                "--disable-mouse",
                "--disable-parallax",
                "--fullscreen-pause-only-active",
            ]

            send(
                [
                    "WIO1",
                    2,
                    "capture_w_engine",
                    "HEADLESS-1",
                    "431960002",
                    captured_artifact,
                    3,
                    60,
                    15,
                    "fill",
                    "border",
                    "background",
                    0,
                    1,
                    1,
                    1,
                    1,
                    1,
                    0,
                    1,
                ]
            )
            event("capture-started", 2)
            _wait_until(
                lambda: capture_log.exists() and b"--screenshot-delay\0" in capture_log.read_bytes(),
                "fake Wallpaper Engine screenshot was not launched",
            )
            capture_args = _nul_fields(capture_log)
            capture_pid = int(capture_args[0])
            assert capture_args[1:] == [
                "--screen-root",
                "HEADLESS-1",
                "--bg",
                "431960002",
                "--scaling",
                "fill",
                "--clamp",
                "border",
                "--fps",
                "60",
                "--layer",
                "background",
                "--volume",
                "15",
                "--noautomute",
                "--no-audio-processing",
                "--disable-particles",
                "--disable-mouse",
                "--disable-parallax",
                "--fullscreen-pause-only-active",
                "--screenshot",
                str(captured_artifact),
                "--screenshot-delay",
                "3",
            ]
            _wait_until(
                lambda: captured_artifact.exists() and captured_artifact.stat().st_size == 8,
                "screenshot fake did not publish its stable partial prefix",
            )
            time.sleep(1.5)
            assert captured_artifact.read_bytes() == screenshot_source.read_bytes()[:8]
            assert _alive(capture_pid), "stable open screenshot was reaped before its writer closed"
            event("captured", 2)
            _wait_until(lambda: not _alive(capture_pid), "successful screenshot child was not reaped")
            assert captured_artifact.read_bytes() == screenshot_source.read_bytes()
            _wait_until(lambda: not _alive(engine_pid), "capture did not stop the exact old renderer")
            assert _alive(sentinel.pid), "successful capture affected an unrelated process"

            capture_log.unlink()
            capture_pid_file.unlink()
            capture_mode.write_text("block", encoding="utf-8")
            send(
                [
                    "WIO1",
                    3,
                    "capture_w_engine",
                    "HEADLESS-1",
                    "431960003",
                    cancelled_artifact,
                    4,
                    30,
                    0,
                    "fit",
                    "clamp",
                    "bottom",
                    1,
                    0,
                    0,
                    0,
                    0,
                    0,
                    1,
                    0,
                ]
            )
            event("capture-started", 3)
            _wait_until(capture_pid_file.exists, "blocked screenshot PID was not recorded")
            cancelled_pid = int(capture_pid_file.read_text(encoding="utf-8").strip())
            _wait_until(lambda: _alive(cancelled_pid), "blocked screenshot child exited unexpectedly")
            _wait_until(
                lambda: cancelled_artifact.exists() and cancelled_artifact.stat().st_size > 0,
                "blocked screenshot did not expose its disposable partial artifact",
            )
            send(["WIO1", 4, "stop", "HEADLESS-1"])
            event("cancelled", 3)
            event("stopped", 4)
            _wait_until(lambda: not _alive(cancelled_pid), "cancel did not reap the screenshot child")
            assert not cancelled_artifact.exists(), "cancel leaked a partial screenshot artifact"
            assert captured_artifact.read_bytes() == screenshot_source.read_bytes(), (
                "cancelling a later capture removed the completed artifact"
            )
            assert _alive(sentinel.pid), "capture cancellation affected an unrelated process"

            capture_log_snapshot = capture_log.read_bytes()
            send(
                [
                    "WIO1",
                    5,
                    "start_w_engine",
                    "HEADLESS-1",
                    "431960005",
                    60,
                    15,
                    "fill",
                    "border",
                    "overlay",
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ]
            )
            invalid_layer = event("error", 5)
            assert invalid_layer[5] == "64" and "invalid layer" in invalid_layer[6]
            assert capture_log.read_bytes() == capture_log_snapshot
            assert _alive(sentinel.pid), "invalid renderer input affected an unrelated process"

            send(
                [
                    "WIO1",
                    6,
                    "start_mpvpaper",
                    "HEADLESS-1",
                    video,
                    "background",
                    1,
                    63,
                    1,
                    1,
                    "FULL",
                    "Vkeep-open=yes",
                ]
            )
            started = event("started", 6)
            assert "controls=mpv-ipc" in started[6]
            _wait_until(mpv_log.exists, "fake mpvpaper was not launched")
            mpv_args = _nul_fields(mpv_log)
            mpv_pid = int(mpv_args[0])
            assert _alive(mpv_pid)
            assert mpv_args[1:6] == ["--layer", "background", "--auto-pause", "--auto-mode", "FULL"]
            assert mpv_args[-2:] == ["HEADLESS-1", str(video)]
            option_index = mpv_args.index("-o")
            options = mpv_args[option_index + 1]
            for option in (
                "loop-file=inf",
                "panscan=1.0",
                "terminal=no",
                "volume=63",
                "mute=yes",
                "hwdec=auto",
                "input-ipc-server=",
                "keep-open=yes",
            ):
                assert option in options
            socket_path = Path(options.split("input-ipc-server=", 1)[1].split()[0])
            _wait_until(
                lambda: socket_path.exists() and stat.S_ISSOCK(socket_path.stat().st_mode),
                "fake mpv IPC socket was not created",
            )
            _wait_until(mpv_socket_mode.exists, "fake mpv IPC mode was not recorded")
            socket_fixture_mode = mpv_socket_mode.read_text(encoding="utf-8")
            assert socket_fixture_mode in {"bound", "restricted-sandbox-symlink"}
            if socket_fixture_mode == "restricted-sandbox-symlink":
                print("note: AF_UNIX bind forbidden; used restricted-sandbox socket fixture")

            send(["WIO1", 7, "pause", "HEADLESS-1"])
            paused = event("paused", 7)
            assert "mode=ipc" in paused[6]
            assert not Path(f"/proc/{mpv_pid}/status").read_text().split("State:", 1)[1].lstrip().startswith("T")
            send(["WIO1", 8, "resume", "HEADLESS-1"])
            event("resumed", 8)

            send(["WIO1", 9, "unmute", "HEADLESS-1"])
            event("unmuted", 9)
            send(["WIO1", 10, "set_volume", "HEADLESS-1", 37])
            volume_event = event("volume-set", 10)
            assert volume_event[6] == "volume=37"
            send(["WIO1", 11, "toggle_mute", "HEADLESS-1"])
            event("muted", 11)
            assert mpv_control_log.read_text(encoding="utf-8").splitlines() == [
                "set pause yes",
                "set pause no",
                "set mute no",
                "set volume 37",
                "set mute yes",
            ]

            send(["WIO1", 11, "stop", "HEADLESS-1"])
            event("ignored", 11)
            assert _alive(mpv_pid), "a stale nonce affected renderer ownership"
            assert _alive(sentinel.pid), "renderer command affected an unrelated process"

            send(["WIO1", 12, "stop", "HEADLESS-1"])
            event("stopped", 12)
            _wait_until(lambda: not _alive(mpv_pid), "stop did not reap the exact owned child")
            assert _alive(sentinel.pid), "stop affected an unrelated process"

            previous_engine_pid = engine_pid
            send(
                [
                    "WIO1",
                    13,
                    "start_w_engine",
                    "HEADLESS-1",
                    "431960013",
                    30,
                    0,
                    "fit",
                    "clamp",
                    "bottom",
                    1,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ]
            )
            event("started", 13)
            _wait_until(
                lambda: int(_nul_fields(engine_log)[0]) != previous_engine_pid,
                "Wallpaper Engine control fixture was not launched",
            )
            engine_pid = int(_nul_fields(engine_log)[0])
            previous_mpv_pid = mpv_pid
            send(["WIO1", 14, "start_mpvpaper", "HEADLESS-2", video, "bottom", 1, 100, 0, 0, "FULL", "E"])
            event("started", 14)
            _wait_until(
                lambda: int(_nul_fields(mpv_log)[0]) != previous_mpv_pid,
                "second-output mpvpaper fixture was not launched",
            )
            coexist_mpv_pid = int(_nul_fields(mpv_log)[0])
            assert _alive(engine_pid) and _alive(coexist_mpv_pid), "disjoint-output renderers did not coexist"

            send(["WIO1", 15, "mute", "HEADLESS-1"])
            unsupported = event("unsupported", 15)
            assert unsupported[5] == "95" and "unavailable" in unsupported[6]
            assert _alive(engine_pid), "unsupported audio control stopped Wallpaper Engine"
            send(["WIO1", 16, "pause", "HEADLESS-1"])
            paused = event("paused", 16)
            assert "mode=signal" in paused[6]
            _wait_until(
                lambda: Path(f"/proc/{engine_pid}/status").read_text().split("State:", 1)[1].lstrip().startswith("T"),
                "Wallpaper Engine pause did not signal its exact child",
            )
            send(["WIO1", 17, "resume", "HEADLESS-1"])
            event("resumed", 17)
            send(["WIO1", 18, "stop", "HEADLESS-2"])
            event("stopped", 18)
            _wait_until(lambda: not _alive(coexist_mpv_pid), "per-output stop leaked the second renderer")

            send(["WIO1", 19, "start_mpvpaper", "HEADLESS-1", video, "bottom", 1, 100, 0, 1, "MAX", "E"])
            event("started", 19)
            _wait_until(lambda: _nul_fields(mpv_log)[0] != str(mpv_pid), "replacement child was not launched")
            _wait_until(lambda: not _alive(engine_pid), "backend hot-swap did not stop the exact prior renderer")
            mpv_pid = int(_nul_fields(mpv_log)[0])

            # Both ':' and '_' are valid output characters. Their private log
            # and IPC names must remain distinct so one output cannot unlink or
            # control the other output's renderer.
            send(["WIO1", 20, "start_mpvpaper", "COLLIDE:A", video, "bottom", 1, 100, 0, 0, "FULL", "E"])
            event("started", 20)
            _wait_until(
                lambda: _nul_fields(mpv_log)[0] != str(mpv_pid),
                "colon-output mpvpaper fixture was not launched",
            )
            colon_args = _nul_fields(mpv_log)
            collision_colon_pid = int(colon_args[0])
            colon_options = colon_args[colon_args.index("-o") + 1]
            colon_socket = Path(colon_options.split("input-ipc-server=", 1)[1].split()[0])
            _wait_until(colon_socket.exists, "colon-output IPC socket was not created")

            send(["WIO1", 21, "start_mpvpaper", "COLLIDE_A", video, "bottom", 1, 100, 0, 0, "FULL", "E"])
            event("started", 21)
            _wait_until(
                lambda: _nul_fields(mpv_log)[0] != str(collision_colon_pid),
                "underscore-output mpvpaper fixture was not launched",
            )
            underscore_args = _nul_fields(mpv_log)
            collision_underscore_pid = int(underscore_args[0])
            underscore_options = underscore_args[underscore_args.index("-o") + 1]
            underscore_socket = Path(underscore_options.split("input-ipc-server=", 1)[1].split()[0])
            _wait_until(underscore_socket.exists, "underscore-output IPC socket was not created")
            assert colon_socket != underscore_socket, "valid output names shared a private IPC path"
            assert colon_socket.exists() and underscore_socket.exists()
            assert _alive(collision_colon_pid) and _alive(collision_underscore_pid)

            send(["WIO1", 22, "stop", "COLLIDE:A"])
            event("stopped", 22)
            _wait_until(lambda: not _alive(collision_colon_pid), "colon-output renderer was not reaped")
            assert _alive(collision_underscore_pid) and underscore_socket.exists(), (
                "stopping the colon output disturbed the underscore output"
            )
            send(["WIO1", 23, "stop", "COLLIDE_A"])
            event("stopped", 23)
            _wait_until(
                lambda: not _alive(collision_underscore_pid),
                "underscore-output renderer was not reaped",
            )
            supervisor.terminate()
            supervisor.wait(timeout=6)
            _wait_until(lambda: not _alive(mpv_pid), "supervisor exit leaked an owned renderer")
            _wait_until(lambda: not fifo.exists(), "supervisor exit leaked its FIFO")
            assert captured_artifact.read_bytes() == screenshot_source.read_bytes(), (
                "supervisor cleanup removed a completed screenshot artifact"
            )
            assert _alive(sentinel.pid), "supervisor cleanup affected an unrelated process"
        finally:
            if supervisor.poll() is None:
                supervisor.terminate()
                try:
                    supervisor.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    supervisor.kill()
                    supervisor.wait(timeout=3)
            for pid in (
                engine_pid,
                capture_pid,
                cancelled_pid,
                mpv_pid,
                coexist_mpv_pid,
                collision_colon_pid,
                collision_underscore_pid,
            ):
                if pid and _alive(pid):
                    os.kill(pid, signal.SIGKILL)
            if sentinel.poll() is None:
                sentinel.terminate()
                sentinel.wait(timeout=3)


def test_motionbgs_contract() -> None:
    """Pin the thin Luau bridge and the separately installed process boundary."""

    bridge = text("motionbgs.luau")
    launcher_path = ROOT / "scripts" / "motionbgs-provider"
    launcher = launcher_path.read_text(encoding="utf-8")
    helper_root = ROOT.parent / "wall-in-one-backend"
    helper_path = helper_root / "wall-in-one-backend"
    helper_tests_path = helper_root / "tests" / "test_backend.py"
    helper = helper_path.read_text(encoding="utf-8")
    helper_tests = helper_tests_path.read_text(encoding="utf-8")

    # The ScriptRuntime entry is now a bounded bridge. In particular, there is
    # no periodic service callback and no provider markup parser left for
    # Noctalia's per-callback CPU watchdog to interrupt.
    require_all(
        bridge,
        (
            "local SCHEMA = 1",
            "local RPC_SCHEMA = 1",
            'local COMMAND_KEY = "wall_in_one_motionbgs_command_v1"',
            'local COMMAND_ACK_KEY = "wall_in_one_motionbgs_command_ack_v1"',
            'local STATUS_KEY = "wall_in_one_motionbgs_status_v1"',
            'active_slug = ""',
            'active_quality = ""',
            "queue_limit = MAX_QUEUE,",
            "queued_downloads = {},",
            'local RESULTS_KEY = "wall_in_one_motionbgs_results_v1"',
            'local INSTALL_URL = "https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/wall-in-one-backend"',
            'local BINARY_NAME = "wall-in-one-backend"',
            'local PROBE_PROTOCOL = "WIO-MBGS-PROBE1"',
            'local RPC_PROTOCOL = "WIO-MBGS-RPC1"',
            "local MAX_QUEUE = 8",
            "local MAX_REQUEST_BYTES = 8 * 1024",
            "local MAX_RESPONSE_BYTES = 128 * 1024",
            "local DOWNLOAD_OPERATION_BUDGET_MS = 75000",
            "local DOWNLOAD_TIMEOUT_MS = 80000",
            "local RPC_OPERATION_BUDGET_MS = 30000",
            'local OPERATION_GUARD_CONTENT = "WIO-MBGS-GUARD1\\n"',
            "local function configuredBinary()",
            'settingString("backend_binary_path", "")',
            "noctalia.commandExists(BINARY_NAME)",
            "local function probeResult(result)",
            'ipairs({ "search", "details", "download", "clear" })',
            "local function launcherRpcResult(operation, result)",
            "local function downloadIsInstalled(slug, quality)",
            'and noctalia.fileExists(sidecar)',
            '(payload.cached ~= true and payload.cached ~= false)',
            'responseSource ~= detail.source_url',
            'fetchedAt ~= detail.fetched_at',
            'sidecar.downloaded_at ~= downloadedAt',
            "readBoundedRegularFile(path, MAX_RESPONSE_BYTES)",
            "local function atomicWriteJson(path, value)",
            "#encoded + 1 > MAX_REQUEST_BYTES",
            'local temporary = path .. ".tmp"',
            "noctalia.renameFile(temporary, path)",
            "local function requestPayload(operation)",
            "guard_path = operation.guard_path",
            "operation_timeout_ms = if operation.kind == \"download\"",
            'if payload.cleared ~= true then',
            '"MotionBGS helper returned an invalid clear result"',
            "local function launchOperation(operation)",
            "local function atomicWriteGuard(path)",
            "operation.request_path, operation.response_path, operation.guard_path = requestPaths(operation)",
            "for _, path in ipairs({ operation.guard_path, operation.request_path, operation.response_path }) do",
            'shellQuote(launcherPath)\n        .. " rpc "',
            "local function startProbe(_force, commandNonce)",
            'shellQuote(launcherPath)\n        .. " probe "',
            'action == "search"',
            "local function queryEncode(value)",
            'local expected = BASE_URL .. "/search?q=" .. queryEncode(request.query)',
            'action == "details" or action == "download"',
            "local function queuedDownloadStatus()",
            "local function downloadIsActiveOrPending(slug, quality)",
            'if action == "download" then',
            "if downloadIsInstalled(slug, quality) then",
            "elseif downloadIsActiveOrPending(slug, quality) then",
            'action == "clear"',
            'action == "probe"',
            "noctalia.state.watch(COMMAND_KEY",
            "function onConfigChanged()",
            "function onExit(_signal, _reason)",
            "binary_available = false",
            "binary_compatible = false",
            'probe_state = "idle"',
            'availability_reason = "initializing"',
            "install_url = INSTALL_URL",
            'publishProbeFailure(requestedNonce, "binary-missing"',
            'pluginDataDirectory:gsub("/+$", "") .. "/motionbgs-bridge-v1"',
            'cacheDirectory = dataDirectory .. "/cache"',
            'rpcDirectory = cacheDirectory .. "/rpc"',
            'local MANAGED_DOWNLOAD_SUFFIX = "/Wall-in-One/MotionBGS"',
            'local MANAGED_DIRECTORY_MARKER = ".wall-in-one-motionbgs-managed.json"',
        ),
        "thin MotionBGS ScriptRuntime bridge",
    )
    assert re.search(r"(?m)^function\s+update\s*\(", bridge) is None
    assert "noctalia.setUpdateInterval" not in bridge
    assert bridge.count("noctalia.runAsync(") == 2, (
        "the bridge should launch only one probe path and one serialized RPC path"
    )
    for parser_artifact in (
        "beginSearchParse",
        "advanceSearchParse",
        "parseListingMeta",
        "parseDetailsHtml",
        "challengePage",
        "SEARCH_ANCHORS_PER_TICK",
        "MAX_HTML_RESPONSE_BYTES",
        "html:gmatch",
        "<a ",
    ):
        assert parser_artifact not in bridge, f"in-process MotionBGS parser artifact remains: {parser_artifact}"
    assert re.search(r"\bcurl\b", bridge, re.IGNORECASE) is None
    assert bridge.count("(payload.cached ~= true and payload.cached ~= false)") == 3
    assert bridge.count("responseSource ~= detail.source_url") == 2
    assert bridge.count("fetchedAt ~= detail.fetched_at") == 2
    assert bridge.count("if payload.cleared ~= true then") == 1

    # The bundled script is only a launcher/protocol gate. It cannot choose a
    # provider URL or perform network work, and it enforces both sides of the
    # request/response size contract before data reaches the ScriptRuntime.
    require_all(
        launcher,
        (
            "set -uo pipefail",
            "readonly probe_wire='WIO-MBGS-PROBE1'",
            "readonly rpc_wire='WIO-MBGS-RPC1'",
            "readonly max_request_bytes=$((8 * 1024))",
            "readonly max_response_bytes=$((128 * 1024))",
            "valid_absolute_path()",
            "owned_regular_file()",
            "owned_writable_directory()",
            "guard_ready()",
            "resolve_binary()",
            "[[ -f $candidate && ! -L $candidate && -x $candidate ]]",
            "binary_subcommand()",
            "subcommand=$(binary_subcommand \"$mode\" probe)",
            "subcommand=$(binary_subcommand \"$mode\" rpc)",
            "[[ -f $path && ! -L $path ]]",
            '[[ $owner == "$(id -u)"',
            "ulimit -f",
            "PYTHONNOUSERSITE=1 PYTHONSAFEPATH=1",
            'run_bounded 8 "$binary" "$subcommand" --protocol 1',
            '"$binary" "$subcommand" --protocol 1 --request "$request" --response "$response" --guard "$guard"',
            "RPC cancellation guard was removed before completion",
            '[[ -e $response || -L $response ]]',
            'owned_regular_file "$response" 2 "$max_response_bytes"',
            '[[ $actual_bytes != "$reported_bytes" ]]',
            "MODE is unified or legacy",
        ),
        "bounded MotionBGS launcher",
    )
    assert re.search(r"\bcurl\b", launcher, re.IGNORECASE) is None
    for forbidden in ("cloudscraper", "selenium", "playwright", "chromedriver"):
        assert forbidden not in launcher.lower()
    subprocess.run(["bash", "-n", str(launcher_path)], check=True)
    launcher_self_test = subprocess.run(
        ["bash", str(launcher_path), "self-test"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    assert launcher_self_test.stdout.strip() == "WIO-MBG1\tok\tself-test"

    # HTTP, HTML parsing, cache mutation, and transactional MP4 installation
    # live in the separately installed unified Python backend, not in Luau.
    assert helper_path.is_file()
    assert helper_path.stat().st_mode & stat.S_IXUSR
    assert helper.startswith("#!/usr/bin/env python3\n")
    require_all(
        helper,
        (
            'VERSION = "1.0.0"',
            "PROTOCOL = 1",
            'PROBE_WIRE = "WIO-MBGS-PROBE1"',
            'RPC_WIRE = "WIO-MBGS-RPC1"',
            "CAPABILITIES = \"search,details,download,clear\"",
            "MAX_REQUEST_BYTES = 8 * 1024",
            "MAX_RESPONSE_BYTES = 128 * 1024",
            "MAX_HTML_BYTES = 1024 * 1024",
            "MAX_CACHE_BYTES = 2 * 1024 * 1024",
            "MAX_SEARCH_CACHE = 8",
            "MAX_DETAIL_CACHE = 48",
            "MAX_REDIRECTS = 3",
            "MIN_OPERATION_TIMEOUT_MS = 5 * 1000",
            "MAX_OPERATION_TIMEOUT_MS = 75 * 1000",
            'GUARD_CONTENT = b"WIO-MBGS-GUARD1\\n"',
            "from html.parser import HTMLParser",
            "class _ListingParser(_BoundedParser):",
            "class _DetailParser(_BoundedParser):",
            "def _validate_request_keys(request: dict[str, Any], action: str) -> None:",
            'action not in {"search", "details", "download", "clear"}',
            "_read_bounded_file(request_path, MAX_REQUEST_BYTES)",
            "only the exact MotionBGS HTTPS origin is accepted",
            '"--disable"',
            '"--proto",\n        "=https"',
            '"--proto-redir",\n        "=https"',
            '"--max-redirs",\n        "0"',
            "if effective != requested:",
            "def _require_guard(path: str) -> None:",
            "def _remaining_seconds(",
            "def _validate_download_route(value: str, quality: str, identifier: str) -> str:",
            "download resolved to a different MotionBGS media id",
            "resource.setrlimit(resource.RLIMIT_FSIZE",
            'transfer["content_type"] not in {"text/html", "application/xhtml+xml"}',
            'prefix[4:8] != b"ftyp"',
            "fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)",
            "os.link(temporary, output, follow_symlinks=False)",
            "os.link(transfer_path, destination, follow_symlinks=False)",
            'CACHE_NAME = "cache-v1.json"',
            'sidecar_destination = destination + ".motionbgs.json"',
            "payload = _encode_json(result, MAX_RESPONSE_BYTES)",
            "size = _write_no_replace(response, payload, MAX_RESPONSE_BYTES)",
            '_emit_fields(RPC_WIRE, "ok", request["request_id"], response, size)',
        ),
        "standalone MotionBGS program",
    )
    for forbidden in ("cloudscraper", "selenium", "playwright", "chromedriver", "requests"):
        assert re.search(
            rf"(?m)^\s*(?:from\s+{re.escape(forbidden)}\b|import\s+{re.escape(forbidden)}\b)",
            helper,
            re.IGNORECASE,
        ) is None, f"standalone backend imports forbidden dependency {forbidden}"
    subprocess.run(["python3", "-m", "py_compile", str(helper_path)], check=True)

    # Keep the external process implementation independently testable. Count
    # the intentionally focused cases and execute them through discovery so a
    # renamed test module cannot silently fall out of this aggregate gate.
    test_methods = re.findall(r"(?m)^    def (test_[a-z0-9_]+)\(", helper_tests)
    assert len(test_methods) >= 19, test_methods
    assert len(set(test_methods)) == len(test_methods)
    helper_env = os.environ.copy()
    helper_env["NO_COLOR"] = "1"
    helper_env.pop("FORCE_COLOR", None)
    helper_suite = subprocess.run(
        ["python3", "-m", "unittest", "discover", "-s", str(helper_root / "tests"), "-p", "test_*.py", "-v"],
        cwd=ROOT.parent,
        env=helper_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=75,
    )
    assert helper_suite.returncode == 0, helper_suite.stdout + helper_suite.stderr
    helper_stderr = ANSI_ESCAPE_RE.sub("", helper_suite.stderr)
    assert ANSI_ESCAPE_RE.sub("", "\x1b[32mOK\x1b[0m") == "OK"
    assert f"Ran {len(test_methods)} tests" in helper_stderr
    assert helper_stderr.rstrip().endswith("OK"), helper_stderr

    # Coordinator state distinguishes the always-available direct site from
    # optional integrated browsing, surfaces helper diagnostics, and lets the
    # user reprobe or open the fixed installation page.
    coordinator = text("service.luau")
    require_all(
        coordinator,
        (
            'local MOTIONBGS_HELPER_URL = "https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/wall-in-one-backend"',
            'backend_binary_path = wallInOne.settingString("backend_binary_path", "")',
            "providers.motionbgs.integration_available = providers.motionbgs.allowed",
            "and motionBgsStatus.available == true",
            "providers.motionbgs.binary_available = type(motionBgsStatus) == \"table\"",
            "providers.motionbgs.binary_compatible = type(motionBgsStatus) == \"table\"",
            "providers.motionbgs.install_url = MOTIONBGS_HELPER_URL",
            "providers.motionbgs.available = providers.motionbgs.browser_available",
            "function wallInOne.openMotionBgsHelper()",
            'elseif kind == "motionbgs_probe" then',
            'elseif kind == "motionbgs_helper_open" then',
            '(action ~= "probe" and providers.motionbgs.integration_available ~= true)',
        ),
        "MotionBGS coordinator integration",
    )

    catalog = tomllib.loads((ROOT.parent / "catalog.toml").read_text(encoding="utf-8"))
    catalog_entry = next(entry for entry in catalog["plugin"] if entry["id"] == "goober/wall-in-one")
    assert catalog_entry["version"] == "0.8.0"
    public_docs = {
        "plugin README": text("README.md").lower(),
        "adapter architecture": text("ADAPTERS.md").lower(),
        "testing guide": text("TESTING.md").lower(),
        "repository README": (ROOT.parent / "README.md").read_text(encoding="utf-8").lower(),
        "changelog": (ROOT.parent / "CHANGELOG.md").read_text(encoding="utf-8").lower(),
        "helper README": (helper_root / "README.md").read_text(encoding="utf-8").lower(),
    }
    for label, document in public_docs.items():
        assert "motionbgs" in document, f"{label} omits MotionBGS"
        assert "wall-in-one-backend" in document, f"{label} omits the external backend name"
    require_all(
        public_docs["plugin README"],
        ("separately installed", "wall-in-one-backend", "library"),
        "Wall-in-One public MotionBGS install/degraded-mode documentation",
    )
    require_all(
        public_docs["adapter architecture"],
        ("process boundary", "8 kib", "128 kib", "has no `update()`"),
        "MotionBGS process-boundary architecture documentation",
    )
    require_all(
        public_docs["testing guide"],
        ("standalone program", "cpu-budget", "missing", "incompatible"),
        "MotionBGS test documentation",
    )
    assert "0.8.0" in public_docs["changelog"]


def test_ui_and_documentation_surface() -> None:
    panel = text("panel.luau")
    widget = text("widget.luau")
    shortcut = text("shortcut.luau")
    for source in (panel, widget, shortcut):
        require_all(
            source,
            (
                'local STATUS_KEY = "wall_in_one_status"',
                'local COMMAND_KEY = "wall_in_one_command"',
            ),
            "UI state protocol",
        )
    require_all(
        panel,
        (
            'local CONFIG_STATE_KEY = "wall_in_one_config_state_v1"',
            'local RUNTIME_STATE_KEY = "wall_in_one_runtime_state_v1"',
            'local LIBRARY_STATE_KEY = "wall_in_one_library_state_v1"',
            'local RENDERER_STATUS_KEY = "wall_in_one_renderer_status_v1"',
            'local MOTIONBGS_STATUS_KEY = "wall_in_one_motionbgs_status_v1"',
            'local MOTIONBGS_RESULTS_KEY = "wall_in_one_motionbgs_results_v1"',
            'local PALETTES_STATUS_KEY = "wall_in_one_palettes_status_v1"',
            'local WALLHAVEN_STATUS_KEY = "wall_in_one_wallhaven_status_v1"',
            'local WALLHAVEN_RESULTS_KEY = "wall_in_one_wallhaven_results_v1"',
            "local function composeStatus()",
            "local function adoptDomain(current, candidate)",
            "local isOpen = false",
            'kind = "playlist_create"',
            'kind = "playlist_rename"',
            'kind = "playlist_duplicate"',
            'kind = "playlist_delete"',
            'kind = "playlist_assign"',
            'kind = "playlist_options"',
            'kind = "output_options"',
            'kind = "playlist_add_entry"',
            'kind = "playlist_remove_entry"',
            'kind = "playlist_apply_entry"',
            'kind = "playlist_action"',
            'kind = "schedule_save"',
            'kind = "schedule_delete"',
            'kind = "schedule_place"',
            'kind = "schedule_resume"',
            'kind = "palettes_refresh"',
            'kind = "wallhaven_search"',
            'kind = "wallhaven_download"',
            'kind = "wallhaven_clear"',
            'kind = "motionbgs_download"',
            'key = "wallhaven-resolution-mode"',
            'key = "wallhaven-top-range"',
            'noctalia.tr("panel.wallhaven.previous_page")',
            'noctalia.tr("panel.wallhaven.next_page")',
            'key = "motionbgs-mode"',
            'key = "motionbgs-genre-preset"',
            'noctalia.tr("panel.motionbgs.mode_latest")',
            'noctalia.tr("panel.motionbgs.genre_presets.custom")',
            '"hello-kitty"',
            'key = "motionbgs-page-" .. tostring(motionPageInputRevision)',
            'noctalia.tr("panel.motionbgs.previous_page")',
            'noctalia.tr("panel.motionbgs.next_page")',
            "local function paletteInventory()",
            '{ id = "audio_volume_down", label = "actions.audio_volume_down" }',
            '{ id = "audio_volume_up", label = "actions.audio_volume_up" }',
            'audio_volume_down = "set_volume"',
            'audio_volume_up = "set_volume"',
            'panelUi.iconActionButton("audio_volume_down", "volume-2", output)',
            'panelUi.iconActionButton("audio_volume_up", "volume-3", output)',
        ),
        "named playlist, schedule, palette, and Wallhaven panel UI",
    )

    provider_index = panel[
        panel.index("function panelUi.providerInstallIndex()") : panel.index(
            "panelUi.motionQueueCache"
        )
    ]
    require_all(
        provider_index,
        (
            'local published = type(currentLibrary.provider_installs) == "table"',
            "nextIndex.wallhaven = type(published.wallhaven) == \"table\"",
            "nextIndex.motionbgs = type(published.motionbgs) == \"table\"",
            "panelUi.providerInstallCache = nextIndex",
            "return nextIndex",
        ),
        "coordinator-published provider install index",
    )
    assert "for _, entry in ipairs" not in provider_index, (
        "store rendering must never cold-scan the full library"
    )

    wallhaven_store = panel[
        panel.index("local function wallhavenSection") : panel.index(
            "local function motionBgsSection"
        )
    ]
    require_all(
        wallhaven_store,
        (
            "local installedItems = panelUi.providerInstallIndex().wallhaven",
            "local installed = installedItems[itemId] ~= nil",
            'tostring(providerStatus.active_action or "") == "download"',
            'local downloadState = if installed then "installed" elseif downloading then "active" else "ready"',
            'text = panelUi.downloadLabel(downloadState, "")',
            'glyph = if installed then "check" elseif downloading then "loader" else "download"',
            "enabled = ready and not busy and not installed",
            'send({ kind = "wallhaven_download", id = tostring(resultItem.id or "") })',
        ),
        "inline Wallhaven card download state and action",
    )
    motionbgs_store = panel[
        panel.index("local function motionBgsSection") : panel.index(
            "local function librarySection"
        )
    ]
    require_all(
        motionbgs_store,
        (
            "local installedItems = panelUi.providerInstallIndex().motionbgs",
            "local queuedDownloads, queuedDownloadCount = panelUi.motionQueueIndex(motionStatus)",
            "local queueDepth = math.max(0, math.floor(tonumber(motionStatus.queue_depth) or 0))",
            "local queueLimit = math.max(1, math.floor(tonumber(motionStatus.queue_limit) or 8))",
            'local recentDownload = type(motionStatus.last_download) == "table" and motionStatus.last_download or {}',
            'local installed = installedItems[stateKey] ~= nil or stateKey == recentDownloadKey',
            "local function downloadButton(requestedQuality)",
            'local stateKey = slug:lower() .. ":" .. requestedQuality',
            "local installed = installedItems[stateKey] ~= nil",
            "local queued = queuedDownloads[stateKey] == true",
            'elseif active then "active"',
            'elseif queued then "queued"',
            "text = panelUi.downloadLabel(downloadState, requestedQuality)",
            "queueDepth < queueLimit",
            'send({ kind = "motionbgs_download", slug = slug, quality = requestedQuality })',
            'downloadButton("hd")',
            'downloadButton("4k")',
        ),
        "inline MotionBGS HD/4K download controls and queue states",
    )
    for provider, source in (("wallhaven", wallhaven_store), ("motionbgs", motionbgs_store)):
        for forbidden in (
            f'kind = "{provider}_detail"',
            f'preview.node("{provider}", selected',
            "results.selected",
        ):
            assert forbidden not in source, (
                f"{provider} store tiles must not reintroduce a duplicate hero/detail round-trip"
            )
    require_all(
        widget,
        (
            'audio_volume_down = "actions.audio_volume_down"',
            'audio_volume_up = "actions.audio_volume_up"',
        ),
        "widget gesture labels",
    )
    assert "audio_set_volume" not in panel, "parameterized volume IPC must not appear as a click action"
    for retired in ("config.reels", "status.cycles", "pair_static"):
        assert retired not in panel, f"panel leaked retired surface {retired!r}"
    open_close = panel[panel.index("function onOpen") : panel.index("function onSettings")]
    require_all(open_close, ("isOpen = true", "isOpen = false", "panel.close()"), "panel lifecycle")
    watcher = panel[panel.index("noctalia.state.watch(STATUS_KEY") :]
    require_all(
        watcher,
        (
            "if adoptLifecycle(nextStatus) then",
            "noctalia.state.watch(CONFIG_STATE_KEY",
            "noctalia.state.watch(RUNTIME_STATE_KEY",
            "noctalia.state.watch(LIBRARY_STATE_KEY",
            "noctalia.state.watch(RENDERER_STATUS_KEY",
            "noctalia.state.watch(MOTIONBGS_STATUS_KEY",
            "noctalia.state.watch(MOTIONBGS_RESULTS_KEY",
            "noctalia.state.watch(PALETTES_STATUS_KEY",
            "noctalia.state.watch(WALLHAVEN_STATUS_KEY",
            "noctalia.state.watch(WALLHAVEN_RESULTS_KEY",
            "refreshPanelState()",
        ),
        "revisioned domain and direct provider watches",
    )
    refresh = panel[panel.index("refreshPanelState = function()") : panel.index("reloadSharedState = function()")]
    require_all(refresh, ("status = composeStatus()", "if isOpen then", "render()"), "closed-panel render gate")
    lifecycle_watch = panel[
        panel.index("noctalia.state.watch(STATUS_KEY") : panel.index("noctalia.state.watch(CONFIG_STATE_KEY")
    ]
    require_all(
        lifecycle_watch,
        (
            "configState = noctalia.state.get(CONFIG_STATE_KEY)",
            "runtimeState = noctalia.state.get(RUNTIME_STATE_KEY)",
            "libraryState = noctalia.state.get(LIBRARY_STATE_KEY)",
            "refreshPanelState()",
        ),
        "coalesced domain commit render",
    )
    domain_watches = panel[
        panel.index("noctalia.state.watch(CONFIG_STATE_KEY") : panel.index(
            "noctalia.state.watch(RENDERER_STATUS_KEY"
        )
    ]
    assert "refreshPanelState()" not in domain_watches, "one domain commit must not rebuild the panel repeatedly"
    for reset in (
        "resetPanelVisibility()",
        "playlistEntryPage = 1",
        "wallhavenVisibleResults = PROVIDER_RESULT_CHUNK",
        "motionBgsVisibleResults = PROVIDER_RESULT_CHUNK",
    ):
        assert reset not in refresh, f"domain update collapsed show-more state via {reset!r}"

    readme = text("README.md").lower()
    for phrase in (
        "0.7",
        "directly starts",
        "does not hand playback",
        "per-display",
        "mpvpaper",
        "wallpaper engine",
        "motionbgs",
        "wallhaven",
        "playlist",
        "schedule",
        "palette",
        "schema 5",
        "schema 6",
        "quick choice",
        "automatic still",
        "screenshot",
        "background",
        "one api-17 renderer service owns",
        "exact foreground child pids",
        "pause/resume/toggle",
        "unsupported runtime audio",
        "provider-previews/v1",
        "64 entries",
        "64 mib",
        "2 mib",
        "same-origin",
        "only as local files",
    ):
        assert phrase in readme, f"README does not document {phrase!r}"
    for retired in (
        "metadata browsers",
        "do not cache or render remote thumbnails",
        "thumbnail cache is intentionally left for a later refinement",
    ):
        assert retired not in readme, f"README still advertises the retired preview limitation: {retired!r}"


def test_declarative_ui_layout_contract() -> None:
    """Reject silent v5 layout mistakes that the Luau compiler cannot type-check."""

    panel = text("panel.luau")
    assert 'variant = "danger"' not in panel, "Noctalia v5 calls the destructive button variant 'destructive'"
    assert "current.daemons" not in panel
    assert 'noctalia.tr("diagnostics.daemons"' not in panel
    assert 'variant = if pairingDeleteArmed then "destructive" else "ghost"' not in panel
    assert 'variant = if pairingResetArmed then "primary" else "ghost"' in panel
    assert panel.count('variant = if managedDeleteArmed then "destructive" else "ghost"') == 1

    box_calls = re.findall(r"ui\.box\(\{(.*?)\}\)", panel, flags=re.DOTALL)
    assert len(box_calls) == panel.count("ui.box({"), "ui.box must not receive a child table"
    for properties in box_calls:
        assert "align =" not in properties and "justify =" not in properties, (
            "ui.box is decorative in Noctalia v5; use a row or column for child layout"
        )

    require_all(
        panel,
        (
            "local BROWSER_GRID_COLUMNS = 4",
            "function panelUi.appendExplicitGrid(children, items, visible, columns, cardBuilder)",
            'preview.node("wallhaven", item, 216, 122, "photo")',
            'preview.node("motionbgs", item, 216, 122, "movie")',
            "panelUi.appendExplicitGrid(children, items, visible, BROWSER_GRID_COLUMNS",
            "local firstWeekdays = {}",
            "local secondWeekdays = {}",
            "local firstMonthRow = {}",
            "local secondMonthRow = {}",
            "local thirdMonthRow = {}",
        ),
        "bounded explicit browser grids and split schedule controls",
    )
    assert panel.count("panelUi.appendExplicitGrid(") == 8, (
        "the grid helper must serve providers, local libraries, the pairing still picker, "
        "the pairing library, playlist-entry source picker, and display playlists"
    )

    explicit_grid = panel[
        panel.index("function panelUi.appendExplicitGrid") : panel.index("function panelUi.actionButton")
    ]
    require_all(
        explicit_grid,
        ('ui.row({ gap = 8, align = "stretch", justify = "start" }, cards)',),
        "equal-height, left-aligned browser grid rows",
    )
    assert 'align = "start"' not in explicit_grid
    assert 'justify = "center"' not in explicit_grid

    # Select values are controlled host widgets. Re-render each draft change so
    # dependent controls and the declared tree agree immediately, rather than
    # waiting for a provider response or a route round-trip.
    immediate_selects = (
        ("wallhaven-categories", "wallhaven-purity"),
        ("wallhaven-purity", "wallhaven-sort"),
        ("wallhaven-sort", "wallhaven-order"),
        ("wallhaven-order", "wallhaven-resolution-mode"),
        ("wallhaven-resolution-mode", "wallhaven-resolution"),
        ("wallhaven-color", "wallhaven-top-range"),
        ("wallhaven-top-range", "wallhaven-page-"),
        ("motionbgs-genre-preset", "motionbgs-genre-"),
    )
    for key, following_key in immediate_selects:
        block = panel[
            panel.index(f'key = "{key}"') : panel.index(f'key = "{following_key}"')
        ]
        require_all(block, ("onChange = function(index)", "render()"), f"immediate {key} selection")
        assert block.index("render()") > block.index("onChange = function(index)")

    genre_block = panel[
        panel.index('key = "motionbgs-genre-preset"') : panel.index(
            'key = "motionbgs-genre-"'
        )
    ]
    assert 'motionBrowseDraft.genre = selectedGenre' in genre_block
    assert 'if selectedGenre ~= ""' not in genre_block, (
        "the Custom genre option must clear the preset draft instead of becoming a no-op"
    )

    require_all(
        panel,
        (
            "local wallhavenSearchInputRevision = 0",
            "local wallhavenPageInputRevision = 0",
            "local motionQueryInputRevision = 0",
            "local motionGenreInputRevision = 0",
            "local motionPageInputRevision = 0",
            'key = "wallhaven-search-" .. tostring(wallhavenSearchInputRevision)',
            'key = "wallhaven-page-" .. tostring(wallhavenPageInputRevision)',
            'key = "motionbgs-search-" .. tostring(motionQueryInputRevision)',
            'key = "motionbgs-genre-" .. tostring(motionGenreInputRevision)',
            'key = "motionbgs-page-" .. tostring(motionPageInputRevision)',
        ),
        "uncontrolled input revision keys",
    )


def test_display_navigation_and_drag_contract() -> None:
    """Pin the display-first navigation and library-backed ordering surfaces."""

    panel = text("panel.luau")
    vm = (ROOT.parent / "tests" / "vm" / "wall-in-one.nix").read_text(encoding="utf-8")
    page_registry = panel[
        panel.index("local panelPages = {") : panel.index("function panelPages.screenNames()")
    ]
    assert "screens = true" not in page_registry, "Displays must remain children of Home, not a top-level route"
    assert "validDisplaySubpages" not in page_registry, "the combined display page must not regain route tabs"

    navigation = panel[
        panel.index("function panelPages.navigationColumn()") : panel.index(
            "function panelPages.locationRequiredSection"
        )
    ]
    require_all(
        navigation,
        (
            'panelPages.navigationButton("main", "panel.nav.main", "home")',
            "local outputs = panelPages.screenNames()",
            '"screen-" .. name',
            "panelPages.selectScreenPage(name)",
        ),
        "Home-nested display navigation",
    )
    assert navigation.index('panelPages.navigationButton("main"') < navigation.index(
        "local outputs = panelPages.screenNames()"
    )
    assert 'panelPages.navigationButton("screens"' not in navigation
    for retired_route in (
        "panel.nav.display_overview",
        "panel.nav.display_engines",
        "panel.nav.display_schedule",
    ):
        assert retired_route not in navigation, f"display navigation still exposes retired route {retired_route!r}"
    require_all(
        navigation,
        (
            "local playlistPages = math.max(1, math.ceil(#playlistIds / PLAYLIST_NAV_PAGE_SIZE))",
            "local firstPlaylist = (playlistNavigationPage - 1) * PLAYLIST_NAV_PAGE_SIZE + 1",
            "local lastPlaylist = math.min(#playlistIds, firstPlaylist + PLAYLIST_NAV_PAGE_SIZE - 1)",
        ),
        "bounded playlist navigation pages",
    )

    select_screen = panel[
        panel.index("function panelPages.selectScreenPage(output)") : panel.index(
            "function panelPages.navigationButton"
        )
    ]
    require_all(
        select_screen,
        (
            "local fallback = tostring(configured.fallback_playlist or \"\")",
            "selectedPlaylistId = if type(playlistMap()[fallback]) == \"table\"",
            'activePage = "main"',
            'activeSubpage = "display"',
        ),
        "display selection and playlist reset",
    )

    display_page = panel[
        panel.index("function panelPages.screensSection()") : panel.index(
            "function panelPages.activePageSections()"
        )
    ]
    require_all(
        display_page,
        (
            "panelUi.displayPlaylistLibrary(output)",
            "schedulesSection(output, playlistId)",
        ),
        "combined visual display playlist and priority page",
    )
    assert display_page.index("panelUi.displayPlaylistLibrary(output)") < display_page.index(
        "schedulesSection(output, playlistId)"
    )
    assert 'key = "screen-default-playlist-" .. output' not in display_page
    active_sections = panel[
        panel.index("function panelPages.activePageSections()") : panel.index("render = function()")
    ]
    require_all(
        active_sections,
        (
            'if activeSubpage == "display" then',
            "local output = panelPages.ensureSelectedScreen()",
            "return { panelPages.screensSection(), panelPages.engineSettingsSection(output) }",
        ),
        "combined display engine page",
    )

    library_section = panel[
        panel.index("local function librarySection") : panel.index("local function playlistActionButton")
    ]
    assert "beginPairingEditor(" not in library_section, "Library must not expose a separate create-pairing button"
    assert 'noctalia.tr("panel.pairings.new")' not in library_section

    token_reconciliation = panel[
        panel.index("local function markDragTokensDirty()") : panel.index(
            "-- Every insertion zone shares one callback."
        )
    ]
    require_all(
        token_reconciliation,
        (
            "dragTokenGeneration += 1",
            "dragReconcile = nil",
            "resetLibraryDragTokens()",
            "local function stepDragTokenReconciliation()",
            "for _ = 1, DRAG_RECONCILE_BATCH do",
            "state.generation ~= dragTokenGeneration",
            'phase = "pairings"',
            "for _, descriptor in ipairs(noctalia.outputs()) do",
            'outputs[output] = { schedules = {} }',
            "playlist.quick_choice ~= true",
            'nextDragToken("r")',
            "state.playlist_by_token[token] = id",
            "state.playlist_token_by_id[id] = token",
            'local namespace = "@schedule:" .. output',
            'nextDragToken("s")',
            'nextDragToken("q")',
            "schedule_output = state.active_output",
            "schedule_id = scheduleId",
            'state.active_target_tokens["@default"] = defaultToken',
            'display_role = "default"',
            'elseif state.phase == "commit" then',
            "dragPlaylistByToken = state.playlist_by_token",
            "dragPlaylistTokenById = state.playlist_token_by_id",
            "libraryPairingCache.index = state.library_pairing_index",
            "dragTokensDirty = false",
        ),
        "bounded opaque playlist and schedule drag-token reconciliation",
    )
    assert token_reconciliation.index('elseif state.phase == "commit" then') \
        < token_reconciliation.index("dragTokensDirty = false")

    panel_update = panel[panel.index("function update()") : panel.index("function onFrameTick")]
    require_all(
        panel_update,
        (
            "local _, redraw = preview.step()",
            "if preview.takeRender() then",
            "panelPages.renderNow()",
            "panelUi.pairingStillChoiceWork()",
            "panelUi.workshopIndexWork()",
            "paletteEntryIndexWork()",
            "preview.settle(isOpen and (dragTokensDirty or stillChoiceWork or workshopIndexWork or paletteIndexWork))",
        ),
        "update-bounded provider scheduler",
    )
    assert "stepDragTokenReconciliation" not in panel_update

    frame_tick = panel[panel.index("function onFrameTick") : panel.index("function onIpc")]
    require_all(
        frame_tick,
        (
            "if isOpen and dragTokensDirty then",
            "if stepDragTokenReconciliation() then",
            "panelUi.pairingStillChoiceWork()",
            "panelUi.stepPairingStillChoiceReconciliation()",
            "render()",
            "panelUi.workshopIndexWork()",
            "panelUi.stepWorkshopIndexReconciliation()",
            "paletteEntryIndexWork()",
            "stepPaletteEntryIndexReconciliation()",
            "preview.settle(isOpen and (dragTokensDirty or stillChoiceWork or workshopIndexWork or paletteIndexWork))",
        ),
        "frame-bounded presentation-data schedulers",
    )
    assert "preview.step()" not in frame_tick
    assert "preview.takeRender()" not in frame_tick
    assert "panelPages.renderNow()" not in frame_tick

    playlist_drop = panel[
        panel.index("function onPlaylistDrop(payload, value)") : panel.index(
            "function onDisplayPlaylistDrop(payload, value)"
        )
    ]
    require_all(
        playlist_drop,
        (
            "local pairingId = dragPairingByToken[payloadToken]",
            "pairingId = dragLibraryPairingByToken[payloadToken]",
        ),
        "separate bounded library drag-token namespace",
    )

    library_watch = panel[
        panel.index("noctalia.state.watch(LIBRARY_STATE_KEY") : panel.index(
            "noctalia.state.watch(RENDERER_STATUS_KEY"
        )
    ]
    require_all(
        library_watch,
        (
            "local adopted, changed = adoptDomain(libraryState, nextState)",
            "if changed then",
            "resetLibraryDragTokens()",
        ),
        "library-generation drag-token retirement",
    )

    schedule_drop = panel[
        panel.index("function onScheduleDrop(payload, value)") : panel.index(
            "function onDisplayPlaylistDrop(payload, value)"
        )
    ]
    require_all(
        schedule_drop,
        (
            'kind = "schedule_place"',
            "output = source.schedule_output",
            "schedule_id = tostring(source.schedule_id or \"\")",
            "anchor_id = tostring(target.schedule_anchor_id or \"\")",
            'placement = tostring(target.schedule_placement or "end")',
        ),
        "schedule drop command",
    )
    display_drop = panel[
        panel.index("function onDisplayPlaylistDrop(payload, value)") : panel.index(
            "local function adaptivePreviewSession"
        )
    ]
    require_all(
        display_drop,
        (
            "local playlistId = dragPlaylistByToken[payloadToken]",
            "if playlistId == nil then",
            "onScheduleDrop(payload, value)",
            'if target.display_role == "default" and target.display_output == selectedScreen then',
            'send({ kind = "playlist_assign", output = selectedScreen, playlist_id = playlistId })',
            'if tostring(target.schedule_output or "") ~= selectedScreen then',
            "resetScheduleDraft(playlistId)",
            'scheduleNameDraft = tostring(playlistMap()[playlistId].name or playlistId)',
            'scheduleInsertBeforeDraft = tostring(target.schedule_before_id or "")',
            "scheduleEditorOpen = true",
        ),
        "display playlist drop assigns row one or opens a positioned schedule editor",
    )
    service = text("service.luau")
    schedule_placement = service[
        service.index("function wallInOne.placeSchedule") : service.index(
            "function wallInOne.weekdayEnabled"
        )
    ]
    require_all(
        schedule_placement,
        (
            'placement ~= "before" and placement ~= "after" and placement ~= "end"',
            'or (placement ~= "end" and anchorId == "")',
            'if sourceIndex == nil or (placement ~= "end" and anchorIndex == nil) then',
            'if placement == "end" then',
            "table.insert(schedules, moving)",
            'if not wallInOne.saveConfig(nextConfig, "schedule-place") then',
            "scheduleReevaluationPending[output] = true",
        ),
        "schedule end-zone append and post-save reevaluation semantics",
    )
    first_place_save = schedule_placement.index('if not wallInOne.saveConfig(nextConfig, "schedule-place") then')
    first_place_pending = schedule_placement.index("scheduleReevaluationPending[output] = true")
    second_place_save = schedule_placement.index(
        'if not wallInOne.saveConfig(nextConfig, "schedule-place") then', first_place_save + 1
    )
    second_place_pending = schedule_placement.index(
        "scheduleReevaluationPending[output] = true", first_place_pending + 1
    )
    assert first_place_save < first_place_pending < second_place_save < second_place_pending
    assert "return false" in schedule_placement[first_place_save:first_place_pending]
    assert "return false" in schedule_placement[second_place_save:second_place_pending]
    schedule_upsert = service[
        service.index("function wallInOne.upsertSchedule") : service.index(
            "function wallInOne.deleteSchedule"
        )
    ]
    require_all(
        schedule_upsert,
        (
            "function wallInOne.upsertSchedule(output, rawSchedule, beforeId)",
            'local requestedAnchor = tostring(beforeId or "")',
            'if tostring(schedule.id or "") == requestedAnchor then',
            "anchor = index",
            "table.insert(outputConfig.schedules, normalized)",
            "table.insert(outputConfig.schedules, anchor, normalized)",
            'if not wallInOne.saveConfig(nextConfig, "schedule-save") then',
            "scheduleReevaluationPending[output] = true",
        ),
        "new scheduled playlist insertion and post-save reevaluation",
    )
    upsert_save = schedule_upsert.index('if not wallInOne.saveConfig(nextConfig, "schedule-save") then')
    upsert_pending = schedule_upsert.index("scheduleReevaluationPending[output] = true")
    assert upsert_save < upsert_pending
    assert "return false" in schedule_upsert[upsert_save:upsert_pending]
    schedule_delete = service[
        service.index("function wallInOne.deleteSchedule") : service.index(
            "function wallInOne.placeSchedule"
        )
    ]
    delete_save = schedule_delete.index('local saved = wallInOne.saveConfig(nextConfig, "schedule-delete")')
    delete_guard = schedule_delete.index("if not saved then", delete_save)
    delete_pending = schedule_delete.index("scheduleReevaluationPending[output] = true", delete_guard)
    assert delete_save < delete_guard < delete_pending
    assert "return false" in schedule_delete[delete_guard:delete_pending]
    commands = service[
        service.index("function wallInOne.handleCommand") : service.index("function update()")
    ]
    assert "wallInOne.upsertSchedule(request.output, request.schedule, request.before_id)" in commands
    assert 'kind == "pairing_delete"' not in commands
    schedule_ui = panel[
        panel.index("local function scheduleInsertionZone") : panel.index(
            "function panelUi.displayPlaylistLibrary"
        )
    ]
    require_all(
        schedule_ui,
        (
            'accepts = { "wio-playlist", "wio-schedule" }',
            'onDrop = "onDisplayPlaylistDrop"',
            "function panelUi.defaultPlaylistDropZone(output)",
            'accepts = { "wio-playlist" }',
            'key = "display-default-row-" .. output .. "-" .. fallbackId',
            'text = "1. " .. fallbackName',
            'dragType = "wio-schedule"',
            "payload = dragToken",
            'text = tostring(scheduleIndex + 1) .. ". " .. scheduledPlaylistName',
            "table.insert(children, scheduleInsertionZone(output, scheduleId))",
            'table.insert(children, scheduleInsertionZone(output, ""))',
            "local scheduleEditorPositioned = false",
            'if scheduleEditorOpen and editingScheduleId == "" and scheduleInsertBeforeDraft == scheduleId then',
            "scheduleEditorPositioned = true",
            "if not scheduleEditorPositioned then",
        ),
        "fixed default row, positioned schedule editor, and playlist-aware priority rows",
    )
    assert schedule_ui.index('text = "1. " .. fallbackName') < schedule_ui.index(
        "for index, schedule in ipairs(schedules) do"
    )
    assert "panel.schedules.move_up" not in schedule_ui
    assert "panel.schedules.move_down" not in schedule_ui

    display_library = panel[
        panel.index("function panelUi.displayPlaylistLibrary") : panel.index(
            "local function playlistsSection"
        )
    ]
    require_all(
        display_library,
        (
            "function panelUi.displayPlaylistLibrary(output)",
            "local ids = sortedPlaylistIds(false)",
            "panelUi.appendExplicitGrid(children, ids, displayPlaylistVisible, 2",
            "previewPath = panelUi.playlistEntryVisualState(first, output)",
            "panelUi.compactPaletteSwatch(first, tostring(first.pairing_id or \"\"))",
            "local dragToken = dragPlaylistTokenById[playlistId]",
            'dragType = "wio-playlist"',
            "payload = dragToken",
            "previewAncestor = 2",
            'send({ kind = "playlist_assign", output = output, playlist_id = playlistId })',
            "resetScheduleDraft(playlistId)",
            "scheduleEditorOpen = true",
        ),
        "visual draggable playlist library for a display",
    )

    playlist_rendering = panel[
        panel.index("local function playlistsSection") : panel.index(
            "local function diagnosticsSection"
        )
    ]
    require_all(
        playlist_rendering,
        (
            "panelUi.playlistPairingLibrary(playlistId, output)",
            "if not editingThisPlaylist then",
            "local playlistPageCount = math.max(1, math.ceil(#entries / PLAYLIST_ENTRY_CHUNK))",
            "then editingPlaylistEntryIndex",
            "else (playlistEntryPage - 1) * PLAYLIST_ENTRY_CHUNK + 1",
            "else math.min(#entries, playlistFirstEntry + PLAYLIST_ENTRY_CHUNK - 1)",
            "for index = playlistFirstEntry, playlistLastEntry do",
            "panelUi.appendPageControls(",
            "local previewPath, sourceAvailable = panelUi.playlistEntryVisualState(entry, output)",
            "playlistEntryPreview(kind, previewPath, active)",
            "panelUi.compactPaletteSwatch(entry, tostring(entry.pairing_id or \"\"))",
            'noctalia.tr("panel.playlists.entry.missing_source")',
            'dragType = "wio-entry"',
            'noctalia.tr("panel.playlists.entry_edit")',
            "beginPlaylistEntryEditor(currentEntry, playlistId, index)",
            "panelUi.playlistEntryEditor(playlistId, output)",
            'kind = "playlist_remove_entry"',
        ),
        "visual playlist rows with bounded graphical entry editing",
    )
    assert "editEntryDraft(" not in playlist_rendering
    assert 'noctalia.tr("panel.playlists.entry_move_up")' not in playlist_rendering
    assert 'noctalia.tr("panel.playlists.entry_move_down")' not in playlist_rendering
    assert 'kind = "playlist_move_entry"' not in playlist_rendering

    playlist_entry_editor = panel[
        panel.index("local function beginPlaylistEntryEditor") : panel.index(
            "local function playlistInsertionZone"
        )
    ]
    require_all(
        playlist_entry_editor,
        (
            "local function beginPlaylistEntryEditor(entry, playlistId, entryIndex)",
            "editingPlaylistEntryPlaylistId = tostring(playlistId or \"\")",
            "editingPlaylistEntryIndex = math.max(0, math.floor(tonumber(entryIndex) or 0))",
            "function panelUi.playlistEntrySourcePicker(output)",
            "ENTRY_SOURCE_PAGE_SIZE",
            "panelUi.pairingStillChoices(",
            "sourceReady = choicesReady",
            "panelUi.libraryItems(kind, offset, ENTRY_SOURCE_PAGE_SIZE)",
            'id = "static"',
            'id = "video"',
            'id = "workshop"',
            "panelUi.appendExplicitGrid(children, items, #items, PLAYLIST_LIBRARY_COLUMNS",
            "panelUi.libraryThumbnail(",
            "panelUi.compactPaletteSwatch(",
            "panelUi.selectPlaylistEntrySource(item)",
            "panelUi.appendPageControls(",
            "pairingEditor(entryMediaKindDraft, { playlist_id = playlistId })",
            'kind = "playlist_replace_entry"',
            "playlist_id = editingPlaylistEntryPlaylistId",
            "entry_id = editingPlaylistEntryId",
            "entry = currentBundle()",
            'noctalia.tr("panel.pairings.still_manual_show")',
            'noctalia.tr("panel.playlists.entry.still_path_placeholder")',
        ),
        "paged library-first playlist-entry editor",
    )
    for obsolete in (
        "panel.playlists.entry.source_still_placeholder",
        "panel.playlists.entry.source_video_placeholder",
        "panel.playlists.entry.source_workshop_placeholder",
    ):
        assert obsolete not in panel

    require_all(
        vm,
        (
            'event == "vm-playlist-entry-editor"',
            "beginPlaylistEntryEditor(playlistEntry, playlistId, playlistEntryIndex)",
            "panelUi.selectPlaylistEntrySource(choice)",
            "panelUi.playlistEntryEditor(playlistId, \"HEADLESS-1\")",
            "editingPlaylistEntryPlaylistId == playlistId",
            "editingPlaylistEntryIndex == playlistEntryIndex",
            "WALL_IN_ONE_VM_PLAYLIST_ENTRY_EDITOR",
            'timeout=20',
            "exceeded its CPU budget",
            "disabled after repeated timeouts",
        ),
        "panel-side graphical playlist-entry VM regression",
    )

    still_reconciliation = panel[
        panel.index("panelUi.pairingStillChoiceCache =") : panel.index(
            "local function pairingEditor"
        )
    ]
    require_all(
        still_reconciliation,
        (
            'ownership == "user" or provider == "local" or provider == "Wallhaven"',
            "local last = math.min(#sourceItems, first + STILL_CHOICE_RECONCILE_BATCH - 1)",
            "for index = first, last do",
            "choiceCache.cursor = last + 1",
            "choiceCache.ready = true",
            "return {}, 0, 1, false",
        ),
        "bounded still-picker eligibility reconciliation",
    )

    workshop_reconciliation = panel[
        panel.index("panelUi.workshopIndexCache =") : panel.index(
            "local function openLibraryEntryPairing"
        )
    ]
    require_all(
        workshop_reconciliation,
        (
            "sourceItems = workshops",
            "index = cached.index",
            "ready = false",
            "local last = math.min(#sourceItems, first + WORKSHOP_INDEX_RECONCILE_BATCH - 1)",
            "for index = first, last do",
            "cached.index = cached.nextIndex",
            "cached.ready = true",
        ),
        "bounded Workshop metadata reconciliation",
    )

    palette_reconciliation = panel[
        panel.index("local PALETTE_INDEX_SOURCES =") : panel.index("local function basename")
    ]
    require_all(
        palette_reconciliation,
        (
            "names = cached.names",
            "nameIndex = cached.nameIndex",
            "byName = cached.byName",
            "ready = false",
            "return cached.names, cached.ready == true, cached.nameIndex",
            "return paletteEntryIndex(source).byName",
            "local last = math.min(#sourceItems, first + PALETTE_INDEX_RECONCILE_BATCH - 1)",
            "for index = first, last do",
            "cached.names = cached.nextNames",
            "cached.byName = cached.nextByName",
            "cached.ready = true",
        ),
        "bounded atomic palette selector indexes",
    )
    palette_name_lookup = palette_reconciliation[
        palette_reconciliation.index("local function paletteNames") : palette_reconciliation.index(
            "local function paletteEntryIndexWork"
        )
    ]
    assert re.search(r"^\s*(for|while)\b", palette_name_lookup, flags=re.MULTILINE) is None

    pairing_index_lookup = panel[
        panel.index("local function indexedLibraryPairings") : panel.index(
            "local function matchingPairingForLibraryEntry"
        )
    ]
    require_all(
        pairing_index_lookup,
        (
            "if not dragTokensDirty then",
            "markDragTokensDirty()",
            "return libraryPairingCache.index",
        ),
        "render-safe library pairing index fallback",
    )
    assert re.search(r"^\s*for\b", pairing_index_lookup, flags=re.MULTILINE) is None

    require_all(
        panel,
        (
            "local function clearAutomaticStillPreparation(kind, source)",
            "clearAutomaticStillPreparation(kind, entryMediaSourceDraft)",
            "closePlaylistEntryEditor()\n                    selectedPlaylistId = ids[",
            "editingPlaylistEntryPlaylistId ~= playlistId",
        ),
        "playlist-entry editor retry and playlist identity guards",
    )

    playlist_zone = panel[
        panel.index("local function playlistInsertionZone") : panel.index(
            "local function scheduleSelectionSummary"
        )
    ]
    assert 'accepts = { "wio-library-item", "wio-entry" }' in playlist_zone


def main() -> None:
    test_manifest_and_translations()
    test_schema_document_fixtures()
    test_coordinator_contract()
    test_steam_handoff_is_disowned_contract()
    test_reusable_pairing_catalog_contract()
    test_item_default_provenance_contract()
    test_renderer_crash_backoff_contract()
    test_coordinator_apply_serialization_contract()
    test_dynamic_pair_fingerprint_contract()
    test_automatic_pairing_preview_contract()
    test_capture_scene_freshness_contract()
    test_managed_library_ownership_contract()
    test_palette_inventory_contract()
    test_backend_binary_discovery_and_setup_contract()
    test_wallhaven_contract()
    test_bounded_fetch_contract()
    test_provider_thumbnail_helper_contract()
    test_provider_preview_panel_contract()
    test_renderer_static_contract()
    test_capture_helper_fallback_validation()
    test_renderer_supervisor()
    test_motionbgs_contract()
    test_ui_and_documentation_surface()
    test_declarative_ui_layout_contract()
    test_display_navigation_and_drag_contract()
    print("Wall-in-One v0.8 offline contract passed.")


if __name__ == "__main__":
    main()
