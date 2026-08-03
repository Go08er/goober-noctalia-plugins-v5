#!/usr/bin/env python3
"""Offline contract gate for Wall-in-One 0.6.

The test deliberately avoids a compositor and the network.  It pins the
manifest/state protocols statically, runs each shell helper's local checks,
and exercises the renderer supervisor with disposable fake renderers so PID
ownership, FIFO cleanup, and exact argv remain observable.
"""

from __future__ import annotations

import base64
import errno
import json
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


def test_manifest_and_translations() -> None:
    manifest_source = text("plugin.toml")
    manifest = tomllib.loads(manifest_source)
    assert manifest["id"] == "goober/wall-in-one"
    assert manifest["name"] == "Wall-in-One"
    assert manifest["version"] == "0.6.0"
    assert manifest["plugin_api"] == 17
    # Dependencies are catalog metadata, not an enable-time gate. Providers
    # still fail soft if an installation is incomplete, while curl is honestly
    # advertised for all three bounded online transports.
    assert manifest["dependencies"] == ["bash", "curl", "sha256sum"]
    assert {entry["id"]: entry["entry"] for entry in manifest["service"]} == {
        "coordinator": "service.luau",
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
    assert required == settings.keys(), sorted(required ^ settings.keys())
    assert "pair_static" not in settings, "pairing is an entry policy, not a global switch"
    retired_renderer_settings = {
        "use_w_engine",
        "use_mpvpaper",
        "use_extra_provider",
        "w_engine_backend",
        "mpvpaper_backend",
        "internal_renderer_layer",
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
        "mpv_auto_pause_mode",
        "mpv_options",
    }
    assert retired_renderer_settings.isdisjoint(settings)
    for setting in settings.values():
        condition = setting.get("visible_when")
        if condition is not None:
            assert condition["key"] in settings, f"dangling visible_when for {setting['key']}"
    assert (
        settings["scene_screenshot_delay"]["default"],
        settings["scene_screenshot_delay"]["min"],
        settings["scene_screenshot_delay"]["max"],
    ) == (15, 1, 120)
    assert settings["sync_colors"]["default"] is False
    assert settings["cycle_start_on_load"]["default"] is False
    assert (settings["cycle_interval_minutes"]["min"], settings["cycle_interval_minutes"]["max"]) == (
        1,
        43200,
    )
    assert settings["motionbgs_quality"]["default"] == "hd"
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
    for field in ("label", "media", "still", "theme"):
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
            'return wallInOne.saveConfig(nextConfig, "schedule-place")',
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
            "if clockSignature ~= scheduleClockSignature and not scheduledBatchActive then",
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
            'kind == "pairing_delete"',
            'kind == "playlist_add_pairing"',
            'kind == "playlist_add_entry"',
            'kind == "playlist_save_entry"',
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
            "paletteAuthorityOutput",
            "runtime.palette",
            "applyGeneration[output]",
            "backendGeneration.w_engine += 1",
            "backendGeneration.mpvpaper += 1",
            "local MAX_LIBRARY_CANDIDATES = 1024",
            "local LIBRARY_SCAN_BATCH = 4",
            "function wallInOne.stepLibraryScan()",
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
    library_refresh = service[
        service.index("wallInOne.refreshLibrary = function()") : service.index(
            "function wallInOne.stepLibraryScan()"
        )
    ]
    for managed_source in ('"managed-wallhaven"', '"managed-auto"'):
        assert library_refresh.index(managed_source) < library_refresh.index(
            "wallInOne.appendLibraryDirectory(mediaEntries, imageRoot"
        )
    assert library_refresh.index('"managed-motionbgs"') < library_refresh.index(
        "wallInOne.appendLibraryDirectory(mediaEntries, videoRoot"
    )
    workshop_discovery = library_refresh[
        library_refresh.index("local workshopCandidates = {}") : library_refresh.index(
            "table.sort(workshopCandidates"
        )
    ]
    assert workshop_discovery.index("if imageRootReady then") < workshop_discovery.index(
        "wallInOne.candidateWorkshopRoots()"
    )
    assert "wallInOne.candidateWorkshopRoots()" not in library_refresh[: library_refresh.index("local workshopCandidates")]
    library_scan = service[
        service.index("function wallInOne.stepLibraryScan()") : service.index(
            "function wallInOne.captureHelper()"
        )
    ]
    require_all(
        library_scan,
        (
            'provider = "local"',
            'candidate.ownership == "managed-motionbgs"',
            'entry.provider = "MotionBGS"',
        ),
        "sidecar-proven shared-root ownership",
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
    assert download_watches.count("wallInOne.refreshLibrary()") == 2
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


def test_reusable_pairing_catalog_contract() -> None:
    """Pin catalog snapshots, occurrence synchronization, and application."""

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
            "function wallInOne.savePairing(rawPairing)",
            "nextConfig.pairings[id] = pairing",
            "wallInOne.syncPairingSnapshots(nextConfig, id)",
            'wallInOne.saveConfig(nextConfig, "pairing-save")',
            "function wallInOne.deletePairing(pairingId)",
            "nextConfig.pairings[pairingId] = nil",
            "entry.pairing_id = nil",
            'wallInOne.saveConfig(nextConfig, "pairing-delete")',
            "function wallInOne.addPairingToPlaylist(output, playlistId, pairingId, beforeId)",
            "local entry = wallInOne.pairingFromEntry(pairing, entryId)",
            "entry.pairing_id = pairing.id",
            "local anchor = wallInOne.entryIndexById(playlist, tostring(beforeId or \"\"))",
            "table.insert(playlist.entries, anchor, entry)",
            'wallInOne.saveConfig(nextConfig, "playlist-add-pairing")',
        ),
        "reusable pairing catalog and playlist occurrence snapshots",
    )

    save_pairing = catalog[
        catalog.index("function wallInOne.savePairing") : catalog.index(
            "function wallInOne.deletePairing"
        )
    ]
    assert save_pairing.index("nextConfig.pairings[id] = pairing") < save_pairing.index(
        "wallInOne.syncPairingSnapshots(nextConfig, id)"
    ) < save_pairing.index('wallInOne.saveConfig(nextConfig, "pairing-save")')

    delete_pairing = catalog[
        catalog.index("function wallInOne.deletePairing") : catalog.index(
            "function wallInOne.addPairingToPlaylist"
        )
    ]
    assert "table.remove(playlist.entries" not in delete_pairing
    for field in ("label", "media", "still", "theme", "added_at"):
        assert f"entry.{field} =" not in delete_pairing, (
            f"catalog deletion rewrote the preserved {field} snapshot"
        )

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
            "if clockSignature ~= scheduleClockSignature and not scheduledBatchActive then",
            "scheduleClockSignature = clockSignature",
            "table.sort(scheduledOutputs)",
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
            "function wallInOne.recordAppliedPair"
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

    record = service[
        service.index("function wallInOne.recordAppliedPair") : service.index(
            "function wallInOne.applyThemePolicy"
        )
    ]
    require_all(
        record,
        (
            "local sourceSize, sourceMtime = wallInOne.dynamicSourceFingerprint(dynamicId)",
            "source_size = tonumber(sourceSize) or 0",
            "source_mtime = tonumber(sourceMtime) or 0",
            "source_size = runtime.pairs[key].source_size",
            "source_mtime = runtime.pairs[key].source_mtime",
        ),
        "pair fingerprint persistence",
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
            '"managed-wallhaven"',
            '"managed-auto"',
            '"managed-motionbgs"',
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
            "function wallInOne.stepLibraryScan"
        )
    ]
    require_all(
        library_refresh,
        (
            "local imageRootReady = wallInOne.existingDirectory(imageRoot)",
            "local videoRootReady = wallInOne.existingDirectory(videoRoot)",
            "if imageRootReady then",
            "if videoRootReady then",
        ),
        "library scan root gating",
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

    scan = service[
        service.index("function wallInOne.stepLibraryScan") : service.index("function wallInOne.captureHelper")
    ]
    require_all(
        scan,
        (
            'ownership = "user"',
            "managed = false",
            "deletable = false",
            'wallInOne.readProviderSidecar(path, ".motionbgs.json", "MotionBGS")',
            'wallInOne.readProviderSidecar(path, ".wallhaven.json", "Wallhaven")',
            "readManagedStillSidecar(path)",
            "entry.managed = true",
            "entry.deletable = true",
        ),
        "fail-closed managed-library classification",
    )

    provider_sidecars = service[
        service.index("function wallInOne.readProviderSidecar") : service.index(
            "function wallInOne.appendLibraryDirectory"
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
        service.index("function wallInOne.sendWallhavenCommand") : service.index(
            "function wallInOne.actionPanelTarget"
        )
    ]
    require_all(
        wallhaven_send,
        (
            "local item = wallInOne.currentWallhavenItem(request.id)",
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

    wallhaven_download = wallhaven[
        wallhaven.index("local function validatedDownload") : wallhaven.index(
            "-- Command protocol and lifecycle"
        )
    ]
    require_all(
        wallhaven_download,
        (
            "download only accepts a wallpaper from the current result set",
            "download requires the exact selected Wallhaven media or short URL",
            'local requiredStaging = target .. ".wallhaven-" .. tostring(nonce) .. ".stage"',
            "download refuses to overwrite an existing target",
            'local sidecar = target .. ".wallhaven.json"',
            'plugin = "goober/wall-in-one"',
            'provider = "Wallhaven"',
            'source = "wallhaven"',
            "source_page = SITE_ORIGIN",
            "bytes = bytes",
            "noctalia.renameFile(request.staging, request.target)",
            "noctalia.renameFile(request.sidecar_stage, request.sidecar)",
            "cleanupNewFile(request.target)",
        ),
        "managed Wallhaven provenance and atomic promotion",
    )
    assert "removeFile(request.target)" not in wallhaven_download

    panel_delete = panel[
        panel.index("local function libraryEntryRow") : panel.index("local function motionBgsSection")
    ]
    require_all(
        panel_delete,
        (
            "local deletable = managed and metadata.deletable == true",
            'local itemId = if deletable then tostring(metadata.id or "") else ""',
            'send({ kind = "library_delete", item_id = itemId })',
        ),
        "opaque managed deletion UI",
    )


def test_palette_inventory_contract() -> None:
    palettes = text("palettes.luau")
    require_all(
        palettes,
        (
            'local STATUS_KEY = "wall_in_one_palettes_status_v1"',
            'local COMMAND_KEY = "wall_in_one_palettes_command_v1"',
            "local PROTOCOL = 1",
            'local COMMUNITY_URL = "https://api.noctalia.dev/palettes"',
            "local MAX_BODY_BYTES = 2 * 1024 * 1024",
            "local MAX_CACHE_BYTES = 2 * 1024 * 1024",
            "local MAX_PALETTES = 512",
            "local MAX_CUSTOM_CANDIDATES = 1024",
            "local MAX_PREVIEW_SWEEP_ENTRIES = 512",
            "local COMMUNITY_TTL_SECONDS = 6 * 60 * 60",
            "local PREVIEW_HASH_TIMEOUT_MS = 20 * 1000",
            "local PINNED_WALLPAPER = {",
            "local PINNED_BUILTIN = {",
            'base .. "/noctalia/palettes"',
            "local function normalizedCommunityCatalog(candidate)",
            "local function normalizedCustomPreview(candidate)",
            "local function loadCommunityCache()",
            "local function atomicWriteCache(entries, fetchedAt, fetchedAtText)",
            "local function cacheIsFresh()",
            "local function configuredImageRoot()",
            'noctalia.getConfig("capture_directory")',
            "local function clearInventoryState()",
            "local function deactivateForMissingImageRoot(reason)",
            "local function initializeForImageRoot(root)",
            'lastEvent = "waiting-for-image-directory"',
            'lastEvent = "image-directory-ready"',
            'local FETCH_PROTOCOL = "WIO-FETCH1"',
            "local function boundedFetchHelper()",
            "local function allocateCommunityTransport(operation)",
            "local function boundedFetchResult(result)",
            '"exec bash"',
            '"palette-catalog"',
            "noctalia.runAsync(command, function(result)",
            "transport.bytes > MAX_BODY_BYTES",
            "communityGeneration += 1",
            "cleanupCommunityTransport(activeCommunityOperation, false)",
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
            "refreshCommunity(command.force == true",
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
            "handleCommand(noctalia.state.get(COMMAND_KEY))",
        ),
        "standalone palette inventory protocol",
    )
    assert "function update()" not in palettes, "palette catalog must not periodically poll the network"
    assert "noctalia.http(" not in palettes, "palette ingress must use the bounded process transport"
    palette_exit = palettes[palettes.index("function onExit(_signal, _reason)") : palettes.index("-- Preserve command monotonicity")]
    require_all(
        palette_exit,
        (
            "cleanupCommunityTransport(activeCommunityOperation, false)",
            "cleanupPreviewOperation(activePreviewOperation)",
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
            'if ready and not consumedCurrentCommand then',
        ),
        "explicit image-root palette startup gate",
    )
    before_startup_gate = palette_startup[: palette_startup.index("if startupImageRoot ~= nil then")]
    for forbidden in (
        "sweepOwnedPreviewFiles()",
        "loadCommunityCache()",
        "refreshCustomPalettes()",
        "refreshCommunity(",
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


def test_wallhaven_contract() -> None:
    wallhaven = text("wallhaven.luau")
    require_all(
        wallhaven,
        (
            "local SCHEMA = 1",
            'local COMMAND_KEY = "wall_in_one_wallhaven_command_v1"',
            'local STATUS_KEY = "wall_in_one_wallhaven_status_v1"',
            'local RESULTS_KEY = "wall_in_one_wallhaven_results_v1"',
            'local API_ORIGIN = "https://wallhaven.cc"',
            'local API_PREFIX = "/api/v1"',
            "local MAX_BODY_BYTES = 512 * 1024",
            "local MAX_RESULTS = 24",
            "local MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024",
            "local MIN_API_INTERVAL_SECONDS = 2",
            'local FETCH_PROTOCOL = "WIO-FETCH1"',
            "local function validatedSearchFilters(command, hasApiKey)",
            "NSFW search requires a Wallhaven API key",
            "local function validatedResolutions(value)",
            "Choose either minimum resolution or exact resolutions, not both",
            'append("resolutions", filters.resolutions)',
            'append("topRange", filters.top_range)',
            'append("seed", filters.seed)',
            "hot = true",
            "local function searchUrl(filters)",
            'noctalia.writeFile(credentialPath, "X-API-Key: " .. key .. "\\n")',
            "local function allocateApiTransport(operation, key)",
            "local function allocateMediaTransport(operation, request)",
            "local function boundedFetchResult(result)",
            "normalizedCdnUrl(value.path, id)",
            "local function findResult(id)",
            "detail only accepts an ID from the current Wallhaven results",
            "download only accepts a wallpaper from the current result set",
            "download requires the exact selected Wallhaven media or short URL",
            "Downloaded content does not match its image extension",
            "local sidecarValue = {",
            'provider = "Wallhaven"',
            "status.last_download = {",
            "nonce == nil or nonce <= status.last_nonce",
            'action == "search"',
            'action == "detail"',
            'action == "download"',
            'action == "clear"',
            "A Wallhaven operation is already in flight",
            "noctalia.state.watch(COMMAND_KEY, handleCommand)",
            "handleCommand(noctalia.state.get(COMMAND_KEY))",
        ),
        "Wallhaven API and command/status contract",
    )

    search_url = wallhaven[
        wallhaven.index("local function searchUrl") : wallhaven.index("local function httpError")
    ]
    assert "apikey" not in search_url.lower(), "API keys must stay in request headers"

    api_request = wallhaven[
        wallhaven.index("local function beginApiRequest") : wallhaven.index("local function search(command")
    ]
    require_all(
        api_request,
        (
            '"exec bash"',
            '"wallhaven-api"',
            'shellQuote(operation.credential_path or "-")',
            "noctalia.runAsync(command, function(result)",
            "boundedFetchResult(result)",
            'validateFetchedFile(operation, transport, "wallhaven-api", url, MAX_BODY_BYTES)',
            "noctalia.readFile(operation.response_path)",
            "removeTransportFile(operation.response_path)",
        ),
        "bounded Wallhaven API transport",
    )
    assert '" .. key' not in api_request, "Wallhaven API keys must not enter helper process argv"
    assert "noctalia.http(" not in wallhaven, "Wallhaven API ingress must use bounded process transport"
    assert "noctalia.download(" not in wallhaven, "Wallhaven media ingress must use bounded process transport"

    media_request = wallhaven[
        wallhaven.index("local function download(command, nonce)") : wallhaven.index(
            "-- Command protocol and lifecycle"
        )
    ]
    require_all(
        media_request,
        (
            '"wallhaven-media"',
            "tostring(expectedBytes)",
            "noctalia.runAsync(transportCommand, function(result)",
            'validateFetchedFile(operation, transport, "wallhaven-media"',
            "transport.bytes ~= expectedBytes",
            "validateDownloadedImage(operation, request, bytes)",
        ),
        "bounded Wallhaven media transport",
    )

    destination = wallhaven[
        wallhaven.index("local function captureDirectory") : wallhaven.index(
            "-- State publication"
        )
    ]
    require_all(
        destination,
        (
            'local configured = settingString("capture_directory", "")',
            'if configured == "" then',
            "return nil",
            "return normalizedDirectory(noctalia.expandPath(configured))",
            "local root = captureDirectory()",
            'root .. "/" .. MANAGED_PARENT_DIRECTORY .. "/" .. MANAGED_WALLHAVEN_DIRECTORY',
            "local markerPath = directory .. \"/\" .. MANAGED_MARKER_NAME",
            'marker.plugin ~= "goober/wall-in-one"',
            'marker.kind ~= "wallhaven"',
            'marker.ownership ~= "managed"',
        ),
        "independently derived Wallhaven managed directory",
    )
    assert "noctalia.wallpaperDirectory()" not in destination
    assert "noctalia.pluginDataDir()" not in destination

    validated_download = wallhaven[
        wallhaven.index("local function validatedDownload") : wallhaven.index(
            "local function validateRequestDestination"
        )
    ]
    require_all(
        validated_download,
        (
            'local requiredTarget = managedDirectory .. "/wallhaven-" .. id .. "." .. extension',
            "if target ~= requiredTarget or not validAbsolutePath(target) then",
            'local requiredStaging = target .. ".wallhaven-" .. tostring(nonce) .. ".stage"',
            "if staging ~= requiredStaging or not validAbsolutePath(staging) then",
            "local directoryOk, markerError = validateManagedDirectory(managedDirectory)",
            'local sidecar = target .. ".wallhaven.json"',
            'local sidecarStage = staging .. ".wallhaven.json"',
            'local nativePart = staging .. ".part"',
            "download refuses to overwrite an existing target, staging file, native part, or provenance sidecar",
        ),
        "Wallhaven destination and nonce staging validation",
    )

    status_publication = wallhaven[
        wallhaven.index("local function statusFingerprint") : wallhaven.index("local function rejectCommand")
    ]
    require_all(
        status_publication,
        (
            "last_download = status.last_download",
            "if force ~= true and fingerprint == lastStatusFingerprint then",
            "status.sequence = statusSequence",
            "noctalia.state.set(STATUS_KEY, status)",
            "noctalia.state.set(RESULTS_KEY, results)",
        ),
        "Wallhaven status/result delta contract",
    )
    for forbidden in ("removeManaged", "deleteManaged", "removeFile(request.target)"):
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
    """Keep remote-provider presentation bounded, local-only, and visibly wired."""

    panel = text("panel.luau")
    require_all(
        panel,
        (
            "local PREVIEW_CACHE_SCHEMA = 1",
            "local PREVIEW_MAX_CONCURRENT = 4",
            "local PREVIEW_MAX_QUEUE = 32",
            "local PREVIEW_MAX_FILE_BYTES = 2 * 1024 * 1024",
            "local PREVIEW_MAX_CACHE_BYTES = 64 * 1024 * 1024",
            "local PREVIEW_MAX_ENTRIES = 64",
            "local PREVIEW_MAX_MANIFEST_BYTES = 64 * 1024",
            "local PREVIEW_MAX_FAILURES = 64",
            "local PREVIEW_RETRY_BASE_SECONDS = 15",
            "local PREVIEW_RETRY_MAX_SECONDS = 300",
            "local PREVIEW_RETRY_POLL_MS = 5000",
            'local PREVIEW_PROTOCOL = "WIO-THUMB1"',
            "local function previewRetryReady(url)",
            "local function previewRetryDue()",
            "local function recordPreviewFailure(url)",
            "local function resetPreviewQueue(scope)",
            "local function setPreviewScope(scope)",
            "local function validPreviewUrl(provider, value)",
            "local function savePreviewManifest()",
            "local function prunePreviewCache()",
            "local function initializePreviewCache()",
            "local function previewHelperResult(result)",
            "local function ensureProviderPreview(provider, identifier, url)",
            "local function providerPreviewNode(provider, item, width, height, glyph)",
            "pumpPreviewQueue = function()",
            "preview.ensure = ensureProviderPreview",
            "preview.node = providerPreviewNode",
            "preview.scope = setPreviewScope",
            "preview.retryDue = previewRetryDue",
            "preview.cancel = function()",
            "preview.close = function()",
        ),
        "panel-owned provider preview manager",
    )
    retry_due = panel[
        panel.index("local function previewRetryDue") : panel.index(
            "local function clearPreviewFailure"
        )
    ]
    require_all(
        retry_due,
        (
            "tonumber(failure.generation) == previewGeneration",
            "tonumber(failure.interest) == previewInterest",
        ),
        "current-visible-generation retry gate",
    )

    url_gate = panel[
        panel.index("local function validPreviewUrl") : panel.index("local function previewKey")
    ]
    require_all(
        url_gate,
        (
            r'value:find("[%c\\#]")',
            "^https://th%.wallhaven%.cc/lg/",
            "bucket == identifier:sub(1, 2)",
            'provider == "motionbgs"',
            "^https://motionbgs%.com/media/",
            "^https://motionbgs%.com/i/c/",
            "tonumber(width) > 4096",
            'extension == "jpg"',
            'extension == "jpeg"',
            'extension == "png"',
            'extension == "webp"',
        ),
        "strict panel-side provider URL gate",
    )
    assert "http://" not in url_gate
    assert "cdn.motionbgs" not in url_gate

    manifest_writer = panel[
        panel.index("local function savePreviewManifest") : panel.index(
            "local function prunePreviewCache"
        )
    ]
    require_all(
        manifest_writer,
        (
            "#encoded + 1 > PREVIEW_MAX_MANIFEST_BYTES",
            'local temporary = previewManifestPath .. ".tmp"',
            "noctalia.writeFile(temporary, encoded",
            "noctalia.renameFile(temporary, previewManifestPath)",
            "noctalia.removeFile(temporary)",
        ),
        "atomic bounded preview manifest writer",
    )
    assert manifest_writer.index("noctalia.writeFile(temporary") < manifest_writer.index(
        "noctalia.renameFile(temporary, previewManifestPath)"
    )

    pruning = panel[
        panel.index("local function prunePreviewCache") : panel.index(
            "local function initializePreviewCache"
        )
    ]
    require_all(
        pruning,
        (
            "table.sort(ordered",
            "> PREVIEW_MAX_ENTRIES",
            "totalBytes > PREVIEW_MAX_CACHE_BYTES",
            "removePreviewEntry(victim.key, true)",
            "totalBytes = math.max(0, totalBytes - victim.bytes)",
        ),
        "fixed-size LRU preview pruning",
    )

    initialization = panel[
        panel.index("local function initializePreviewCache") : panel.index(
            "local function previewShellQuote"
        )
    ]
    require_all(
        initialization,
        (
            "noctalia.pluginDir()",
            "noctalia.pluginDataDir()",
            '"/scripts/provider-thumbnail"',
            '"/provider-previews/v1"',
            '"/manifest.json"',
            "noctalia.mkdirAll(previewCacheDirectory)",
            "tonumber(manifestInfo.size) <= PREVIEW_MAX_MANIFEST_BYTES",
            "#raw <= PREVIEW_MAX_MANIFEST_BYTES",
            "tonumber(decoded.schema) == PREVIEW_CACHE_SCHEMA",
            "previewEntryValid(key, entry)",
            "prunePreviewCache()",
            "noctalia.listDir(previewCacheDirectory)",
            'name == "manifest.json.tmp"',
        ),
        "bounded preview cache initialization and schema discard",
    )
    assert initialization.index("noctalia.fileInfo(previewManifestPath)") < initialization.index(
        "noctalia.readFile(previewManifestPath)"
    )

    helper_result = panel[
        panel.index("local function previewHelperResult") : panel.index(
            "local function previewExtension"
        )
    ]
    require_all(
        helper_result,
        (
            "result.timedOut == true",
            "tonumber(result.exitCode) ~= 0",
            "protocol ~= PREVIEW_PROTOCOL",
            'outcome ~= "ok"',
        ),
        "thumbnail helper result protocol gate",
    )

    completion = panel[
        panel.index("local function finishPreviewTask") : panel.index("pumpPreviewQueue = function()")
    ]
    require_all(
        completion,
        (
            "transport.provider == task.provider",
            "transport.effective_url == task.url",
            "transport.path == task.staging_path",
            "transport.bytes <= PREVIEW_MAX_FILE_BYTES",
            "math.floor(tonumber(info.size) or 0) == transport.bytes",
            "task.generation ~= previewGeneration",
            "noctalia.removeFile(task.staging_path)",
            "clearPreviewFailure(task.url)",
            "recordPreviewFailure(task.url)",
            "noctalia.renameFile(task.staging_path, finalPath)",
            "prunePreviewCache()",
            "savePreviewManifest()",
            "noctalia.removeFile(task.staging_path)",
        ),
        "post-helper preview promotion gate",
    )

    pump = panel[
        panel.index("pumpPreviewQueue = function()") : panel.index(
            "local function ensureProviderPreview"
        )
    ]
    require_all(
        pump,
        (
            "previewActive < PREVIEW_MAX_CONCURRENT",
            "task.generation == previewGeneration",
            "previewPending[task.key] == nil",
            "previewRetryReady(task.url)",
            '" fetch "',
            "previewShellQuote(task.provider)",
            "previewShellQuote(task.url)",
            "previewShellQuote(task.staging_path)",
            "noctalia.runAsync(command",
            "40000",
        ),
        "bounded and de-duplicated preview work queue",
    )

    ensure = panel[
        panel.index("local function ensureProviderPreview") : panel.index(
            "local function providerPreviewNode"
        )
    ]
    require_all(
        ensure,
        (
            "#previewQueue < PREVIEW_MAX_QUEUE",
            "generation = previewGeneration",
            "previewRetryReady(safeUrl)",
        ),
        "hard-bounded generation-aware preview enqueue",
    )
    assert "previewFailedUrls" not in panel, "preview failures must not remain permanent for the runtime"

    preview_node = panel[
        panel.index("local function providerPreviewNode") : panel.index(
            "local function resetLibraryVisibility"
        )
    ]
    require_all(
        preview_node,
        (
            "previewAbsolutePath(path)",
            "noctalia.fileExists(path)",
            "return ui.image({",
            "path = path",
            'fit = "cover"',
            "return ui.row({",
        ),
        "local-file preview node with placeholder fallback",
    )
    for forbidden in ("http://", "https://", "thumbnail_url", "poster_url", "thumbs"):
        assert forbidden not in preview_node, f"preview image node can consume remote data directly: {forbidden}"

    wallhaven_section = panel[
        panel.index("local function wallhavenSection") : panel.index("local function motionBgsSection")
    ]
    motionbgs_section = panel[
        panel.index("local function motionBgsSection") : panel.index("local function librarySection")
    ]
    for source, provider, remote_field in (
        (wallhaven_section, "wallhaven", "thumbs"),
        (motionbgs_section, "motionbgs", "thumbnail_url"),
    ):
        require_all(
            source,
            (
                remote_field,
                f'preview.ensure("{provider}"',
                f'preview.node("{provider}"',
            ),
            f"visible {provider} preview wiring",
        )
        assert "if value <" in source and "preview.cancel()" in source, (
            f"{provider} show-fewer can leave invisible preview work queued"
        )

    wallhaven_fetches = wallhaven_section[
        wallhaven_section.index("local ready =") : wallhaven_section.index("local sortingValues")
    ]
    motionbgs_fetches = motionbgs_section[
        motionbgs_section.index("local integrationReady =") : motionbgs_section.index("local children =")
    ]
    for source, readiness, provider in (
        (wallhaven_fetches, "if ready then", "wallhaven"),
        (motionbgs_fetches, "if integrationReady then", "motionbgs"),
    ):
        assert readiness in source
        assert source.index(readiness) < source.index(f'preview.ensure("{provider}"'), (
            f"{provider} previews can fetch while the integration is force-disabled"
        )
        assert f'preview.scope("{provider}:"' in source

    on_close = panel[panel.index("function onOpen") : panel.index("function onSettings")]
    assert "preview.close()" in on_close, "closing the panel must cancel queued preview presentation work"
    on_settings = panel[panel.index("function onSettings") : panel.index("function onIpc")]
    assert "preview.close()" in on_settings, "opening settings must cancel queued preview presentation work"
    require_all(
        on_settings,
        ("function update()", "if isOpen and preview.retryDue() then", "render()"),
        "bounded preview retry wakeup",
    )
    assert "noctalia.setUpdateInterval(preview.retryPollMs)" in panel

    navigation = panel[
        panel.index("function panelPages.selectPage") : panel.index(
            "function panelPages.navigationButton"
        )
    ]
    assert navigation.count("preview.cancel()") >= 3, "page changes must retire invisible preview generations"

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
    service = text("motionbgs.luau")
    helper_path = ROOT / "scripts" / "motionbgs-provider"
    helper = helper_path.read_text(encoding="utf-8")
    require_all(
        service,
        (
            "local SCHEMA = 1",
            "local CACHE_SCHEMA = 2",
            'local COMMAND_KEY = "wall_in_one_motionbgs_command_v1"',
            'local COMMAND_ACK_KEY = "wall_in_one_motionbgs_command_ack_v1"',
            'local STATUS_KEY = "wall_in_one_motionbgs_status_v1"',
            'local RESULTS_KEY = "wall_in_one_motionbgs_results_v1"',
            "local MAX_RESULTS = 48",
            "local SEARCH_ANCHORS_PER_TICK = 1",
            "local SEARCH_PARSE_INTERVAL_MS = 16",
            "local IDLE_UPDATE_INTERVAL_MS = 250",
            "local function setUpdateCadence(intervalMs)",
            "noctalia.setUpdateInterval(intervalMs)",
            "local MAX_QUEUE = 8",
            "local MAX_CACHE_SEARCHES = 8",
            "local MAX_CACHE_DETAILS = 48",
            "local MAX_HTML_RESPONSE_BYTES = 1024 * 1024",
            'local MANAGED_DOWNLOAD_SUFFIX = "/Wall-in-One/MotionBGS"',
            'local MANAGED_DIRECTORY_MARKER = ".wall-in-one-motionbgs-managed.json"',
            '"deletion_authority":"adjacent .motionbgs.json sidecar required"',
            'settingInt("motionbgs_result_limit", MAX_RESULTS, 1, MAX_RESULTS)',
            'settingInt("motionbgs_cache_minutes", 30, 5, 1440)',
            'settingInt("motionbgs_max_download_mb", 256, 16, 512)',
            'configuredDirectory("video_directory")',
            'videoRoot .. MANAGED_DOWNLOAD_SUFFIX',
            "local function configuredVideoRootExists()",
            'local function prepareDownloadDirectory()',
            'if not providerAvailable() then',
            'local rootInfo = videoRoot ~= "" and noctalia.fileInfo(videoRoot) or nil',
            'local made, makeError = noctalia.mkdirAll(directory)',
            'writeManagedDirectoryMarker(directory)',
            'cacheDirectory = dataDirectory .. "/motionbgs"',
            'quality == "4k"',
            'kind == "site-markup" or kind == "challenge"',
            "challengePage",
            "local function beginSearchParse(html, limit)",
            "local function appendSearchCard(parser, attributes, body)",
            "local function advanceSearchParse(parser)",
            "processed < SEARCH_ANCHORS_PER_TICK",
            'local normalizedDigits = digits:gsub(",", "")',
            "tonumber(normalizedDigits)",
            "local function beginSearchOperation(operation, transport)",
            "local function advanceSearchOperation(operation)",
            "parser.ready = true",
            "deferred = beginSearchOperation(operation, transport)",
            "if not deferred then",
            'type(activeOperation.search_parse) == "table"',
            "advanceSearchOperation(activeOperation)",
            "local function normalizedBrowseRequest(candidate)",
            "local function browseUrl(request)",
            "local function canonicalSearchSlug(value)",
            "local function listingRouteMatches(request, value)",
            "local function parseListingMeta(html, request, itemCount)",
            'mode ~= "search" and mode ~= "latest" and mode ~= "genre" and mode ~= "4k" and mode ~= "hd"',
            "MotionBGS text search does not expose pagination",
            "MotionBGS currently redirects HD pages after page 1 into the unfiltered catalog",
            'request.mode == "latest" or request.mode == "genre" or request.mode == "4k"',
            'request.mode == "latest"',
            'return table.concat({',
            "parseDetailsHtml",
            "normalizeStillImageUrl",
            'for _, attribute in ipairs({ "data-src", "data-lazy-src", "data-original", "src" }) do',
            'for _, attribute in ipairs({ "data-srcset", "srcset", "data-src", "src" }) do',
            'candidate:match("^%s*([^%s]+)")',
            'spanText(body, "ttl")',
            'path:match("^/dl/([%w]+)/(%d+)/?$")',
            "normalizeSiteUrl",
            "cache.searches",
            "cache.details",
            "local function rebuildOrderedCache(order, values, maximum, validator)",
            "if #reversed >= maximum then",
            "rebuildOrderedCache(candidate.search_order, candidate.searches, MAX_CACHE_SEARCHES, validCachedSearch)",
            "rebuildOrderedCache(candidate.detail_order, candidate.details, MAX_CACHE_DETAILS, validCachedDetail)",
            "nonceValue(command.nonce)",
            'action == "search"',
            'action == "details"',
            'action == "download"',
            'action == "clear"',
            "noctalia.state.watch(COMMAND_KEY",
            "function onConfigChanged()",
            "local operationGeneration = 0",
            "local function invalidateOperations(message, forceBarrier)",
            "operationGeneration += 1",
            "setUpdateCadence(IDLE_UPDATE_INTERVAL_MS)",
            "setUpdateCadence(SEARCH_PARSE_INTERVAL_MS)",
            "operation.generation ~= operationGeneration",
            'return nil, "protocol", "MotionBGS helper returned a cross-origin or malformed effective URL"',
            "local function cleanupCancelledDownload(operation, result)",
            "local path = validatedDownloadPath(operation, transport)",
            'noctalia.removeFile(path .. ".motionbgs.json")',
            'invalidateOperations("MotionBGS requests were cancelled by cache clear", true)',
            'invalidateOperations("MotionBGS integration was disabled or became unavailable", false)',
            "function onExit(_signal, _reason)",
            "acknowledgeCancellation(activeOperation, cancellation)",
            "for _, operation in ipairs(pendingOperations) do",
            "noctalia.state.set(STATUS_KEY, status)",
        ),
        "MotionBGS service",
    )
    assert service.count('local function hasClass(attributes, wanted)') == 1

    def integer_constant(name: str) -> int:
        match = re.search(rf"^local {re.escape(name)} = ([0-9]+)$", service, re.MULTILINE)
        assert match is not None, f"MotionBGS service is missing integer constant {name}"
        return int(match.group(1))

    anchors_per_tick = integer_constant("SEARCH_ANCHORS_PER_TICK")
    parse_interval_ms = integer_constant("SEARCH_PARSE_INTERVAL_MS")
    idle_interval_ms = integer_constant("IDLE_UPDATE_INTERVAL_MS")
    assert anchors_per_tick == 1, "MotionBGS parser must preserve one anchor per callback"
    assert parse_interval_ms == 16
    assert idle_interval_ms == 250
    # A current provider page has about 170 unrelated navigation/footer anchors
    # in addition to its 36 wallpaper cards. Include the EOF and publication
    # callbacks so a cadence regression cannot silently restore a ~52s parse.
    realistic_anchor_count = 170 + 36
    realistic_parse_callbacks = (realistic_anchor_count + anchors_per_tick - 1) // anchors_per_tick + 2
    assert realistic_parse_callbacks * parse_interval_ms <= 3500

    cadence_helper = service[
        service.index("local function setUpdateCadence") : service.index("local previousStatus")
    ]
    require_all(
        cadence_helper,
        (
            "currentUpdateIntervalMs == intervalMs",
            "noctalia.setUpdateInterval(intervalMs)",
            "currentUpdateIntervalMs = intervalMs",
        ),
        "MotionBGS update-cadence helper",
    )
    assert service.count("noctalia.setUpdateInterval(") == 1

    invalidation = service[
        service.index("local function invalidateOperations") : service.index("local function nonceValue")
    ]
    assert "setUpdateCadence(IDLE_UPDATE_INTERVAL_MS)" in invalidation
    finish_operation = service[
        service.index("local function finishNetworkOperation") : service.index("local function beginSearchOperation")
    ]
    assert finish_operation.index("setUpdateCadence(IDLE_UPDATE_INTERVAL_MS)") < finish_operation.index(
        "activeOperation == operation"
    )
    begin_search = service[
        service.index("local function beginSearchOperation") : service.index("local function advanceSearchOperation")
    ]
    assert begin_search.index("operation.search_parse = parser") < begin_search.index(
        "setUpdateCadence(SEARCH_PARSE_INTERVAL_MS)"
    )
    launch_failure = service[
        service.index("if not accepted then") : service.index("return true", service.index("if not accepted then"))
    ]
    assert "finishNetworkOperation(operation)" in launch_failure
    exit_handler = service[service.index("function onExit") : service.index("initializeStorage()", service.index("function onExit"))]
    assert "setUpdateCadence(IDLE_UPDATE_INTERVAL_MS)" in exit_handler
    assert service.count("setUpdateCadence(IDLE_UPDATE_INTERVAL_MS)") >= 4

    route_validation = service[
        service.index("local function canonicalSearchSlug") : service.index("local function normalizeStillImageUrl")
    ]
    require_all(
        route_validation,
        (
            'return validSlug(query:lower():gsub("%s+", "-"))',
            'actual == "/search"',
            "local canonicalSlug = canonicalSearchSlug(request.query)",
            'actual == "/tag:" .. canonicalSlug',
        ),
        "exact MotionBGS canonical search redirect",
    )
    cache_validation = service[
        service.index("local function validCachedSearch") : service.index("local function validCachedDetail")
    ]
    assert "not listingRouteMatches(request, record.source_url)" in cache_validation

    still_parser = service[
        service.index("local function normalizeStillImageUrl") : service.index(
            "local function challengePage"
        )
    ]
    require_all(
        still_parser,
        (
            "^https://motionbgs%.com/media/",
            "^https://motionbgs%.com/i/c/",
            "tonumber(width) > 4096",
            'lower:match("%.jpe?g$")',
            'attributeValue(attributes, attribute)',
            '"data-src", "data-lazy-src", "data-original", "src"',
            '"data-srcset", "srcset", "data-src", "src"',
        ),
        "MotionBGS lazy still candidate selection",
    )
    assert still_parser.index('"data-src"') < still_parser.index('"src"'), (
        "MotionBGS lazy data-src must be considered before a placeholder src"
    )

    bounded_reader = service[
        service.index("local function readBoundedRegularFile") : service.index(
            "local function configuredDirectory"
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
        "MotionBGS bounded regular-file reader",
    )
    assert bounded_reader.index("noctalia.fileInfo(path)") < bounded_reader.index("noctalia.readFile(path)")

    managed_marker = service[
        service.index("local function writeManagedDirectoryMarker") : service.index(
            "local function prepareDownloadDirectory"
        )
    ]
    require_all(
        managed_marker,
        (
            "readBoundedRegularFile(marker, MAX_MANAGED_MARKER_BYTES)",
            "current ~= MANAGED_DIRECTORY_MARKER_CONTENT",
            "managed MotionBGS directory marker is invalid",
        ),
        "fail-closed MotionBGS marker read",
    )
    assert "noctalia.readFile(marker)" not in managed_marker

    cache_load = service[
        service.index("local function loadCache") : service.index("local function fresh")
    ]
    require_all(
        cache_load,
        ("readBoundedRegularFile(cachePath, MAX_CACHE_BYTES)", "#raw > MAX_CACHE_BYTES"),
        "bounded MotionBGS cache read",
    )
    assert "noctalia.readFile(cachePath)" not in cache_load

    search_response = service[
        service.index("local function beginSearchOperation") : service.index("local function enqueueDownload")
    ]
    detail_response = service[
        service.index("local function performDetails") : service.index("local function performDownload")
    ]
    for response_reader in (search_response, detail_response):
        assert "readBoundedRegularFile(transport.path, MAX_HTML_RESPONSE_BYTES)" in response_reader
        assert "noctalia.readFile(transport.path)" not in response_reader

    configured_download = service[
        service.index("local function configuredDownloadDirectory") : service.index(
            "local function cacheTtlSeconds"
        )
    ]
    require_all(
        configured_download,
        (
            'local videoRoot = configuredDirectory("video_directory")',
            'videoRoot .. MANAGED_DOWNLOAD_SUFFIX',
        ),
        "MotionBGS download-directory resolution",
    )
    assert "motionbgs_download_directory" not in service

    prepare_download = service[
        service.index("local function prepareDownloadDirectory") : service.index("local function publishStatus")
    ]
    assert prepare_download.index('noctalia.fileInfo(videoRoot)') < prepare_download.index(
        "if not providerAvailable() then"
    )
    assert prepare_download.index("if not providerAvailable() then") < prepare_download.index(
        "noctalia.mkdirAll(directory)"
    )
    assert prepare_download.index("noctalia.mkdirAll(directory)") < prepare_download.index(
        "writeManagedDirectoryMarker(directory)"
    )

    initialize_storage = service[
        service.index("local function initializeStorage") : service.index("function update()")
    ]
    require_all(
        initialize_storage,
        (
            "not configuredVideoRootExists()",
            'not settingBool("use_motionbgs", true)',
            "or not status.curl_available",
            "or not status.helper_available",
            'cacheDirectory = dataDirectory .. "/motionbgs"',
            "prepareDownloadDirectory()",
        ),
        "separate MotionBGS metadata and managed-media storage",
    )
    assert initialize_storage.index("not configuredVideoRootExists()") < initialize_storage.index(
        "noctalia.pluginDataDir()"
    )

    validated_download = service[
        service.index("local function validatedDownloadPath") : service.index(
            "local function cleanupCancelledDownload"
        )
    ]
    require_all(
        validated_download,
        (
            'local sidecarPath = path .. ".motionbgs.json"',
            "readBoundedRegularFile(sidecarPath, MAX_PROVIDER_SIDECAR_BYTES)",
            "#sidecarRaw <= MAX_PROVIDER_SIDECAR_BYTES",
            "or tonumber(sidecar.schema) ~= 1",
            'or sidecar.plugin ~= "goober/wall-in-one"',
            'or sidecar.provider ~= "MotionBGS"',
            "or sidecar.path ~= path",
            'or sidecar.source_page ~= BASE_URL .. "/" .. tostring(operation.slug or "")',
            "or tonumber(sidecar.bytes) ~= bytes",
        ),
        "MotionBGS helper-result provenance validation",
    )
    assert "noctalia.readFile(sidecarPath)" not in validated_download
    require_all(
        helper,
        (
            "expected fetch-html, download, or self-test",
            "WIO-MBG1",
            "fetch-html",
            "download",
            "self-test",
            "max_redirects=3",
            "same-origin",
            "exec curl --disable",
            ".motionbgs-body.",
            ".motionbgs.json",
            'printf \'  "plugin": "goober/wall-in-one",\\n\'',
            'printf \'  "provider": "MotionBGS",\\n\'',
            'printf \'  "path": "%s",\\n\' "$(json_escape "$final")"',
            'mv -f -- "$body" "$output"',
            'mv -f -- "$sidecar_tmp" "$sidecar"',
        ),
        "MotionBGS helper",
    )
    motion_curl = helper[helper.index("exec curl") : helper.index("curl_rc=$?")]
    assert motion_curl.index("--disable") < motion_curl.index("--silent")
    for forbidden in ("cloudscraper", "selenium", "playwright", "chromedriver"):
        assert forbidden not in helper.lower(), f"MotionBGS helper attempts challenge bypass: {forbidden}"

    syntax_targets = [
        ROOT / "scripts" / "capture-still",
        ROOT / "scripts" / "renderer-supervisor",
        helper_path,
    ]
    for script in syntax_targets:
        subprocess.run(["bash", "-n", str(script)], check=True)
    result = subprocess.run(
        ["bash", str(helper_path), "self-test"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    assert result.stdout.strip() == "WIO-MBG1\tok\tself-test", result.stdout

    # Exercise the helper's successful download path without touching the
    # network. This verifies the adjacent sidecar values as serialized, rather
    # than merely pinning source-code strings.
    with tempfile.TemporaryDirectory(prefix="wall-in-one-motionbgs-provenance-") as temporary:
        temp = Path(temporary)
        fake_bin = temp / "bin"
        fake_bin.mkdir()
        fake_curl = fake_bin / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env bash
set -u
header=
output=
url=
while (( $# > 0 )); do
  case $1 in
    --dump-header) header=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $header && -n $output && $url == https://motionbgs.com/* ]] || exit 64
printf 'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\r\n' >"$header"
printf '0000ftypisomwall-in-one-fixture' >"$output"
printf '200'
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        downloads = temp / "downloads"
        downloads.mkdir()
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment.get('PATH', '')}"
        downloaded = subprocess.run(
            [
                "bash",
                str(helper_path),
                "download",
                "42",
                "fixture-motion",
                "hd",
                str(downloads),
                "Fixture Motion",
                "16",
                "10",
            ],
            check=True,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        fields = downloaded.stdout.strip().split("\t")
        assert fields[:3] == ["WIO-MBG1", "ok", "200"], downloaded.stdout
        payload = Path(fields[-1])
        assert payload == downloads / "fixture-motion.hd.mp4"
        provenance = json.loads(Path(f"{payload}.motionbgs.json").read_text(encoding="utf-8"))
        assert provenance["schema"] == 1
        assert provenance["plugin"] == "goober/wall-in-one"
        assert provenance["provider"] == "MotionBGS"
        assert provenance["path"] == str(payload)
        assert provenance["source_page"] == "https://motionbgs.com/fixture-motion"
        assert provenance["bytes"] == payload.stat().st_size


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
            'kind = "playlist_save_entry"',
            'kind = "playlist_remove_entry"',
            'kind = "playlist_move_entry"',
            'kind = "playlist_apply_entry"',
            'kind = "playlist_action"',
            'kind = "schedule_save"',
            'kind = "schedule_delete"',
            'kind = "schedule_place"',
            'kind = "schedule_resume"',
            'kind = "palettes_refresh"',
            'kind = "wallhaven_search"',
            'kind = "wallhaven_detail"',
            'kind = "wallhaven_download"',
            'kind = "wallhaven_clear"',
            'key = "wallhaven-resolution-mode"',
            'key = "wallhaven-top-range"',
            'noctalia.tr("panel.wallhaven.previous_page")',
            'noctalia.tr("panel.wallhaven.next_page")',
            'key = "motionbgs-mode"',
            'key = "motionbgs-genre-preset"',
            'noctalia.tr("panel.motionbgs.mode_latest")',
            'noctalia.tr("panel.motionbgs.genre_presets.custom")',
            '"hello-kitty"',
            'key = "motionbgs-page"',
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
        "playlistVisibleEntries = PLAYLIST_ENTRY_CHUNK",
        "wallhavenVisibleResults = PROVIDER_RESULT_CHUNK",
        "motionBgsVisibleResults = PROVIDER_RESULT_CHUNK",
    ):
        assert reset not in refresh, f"domain update collapsed show-more state via {reset!r}"

    readme = text("README.md").lower()
    for phrase in (
        "0.6",
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
        "same-origin redirects",
        "only as local files",
    ):
        assert phrase in readme, f"README does not document {phrase!r}"
    for retired in (
        "metadata browsers",
        "do not cache or render remote thumbnails",
        "thumbnail cache is intentionally left for a later refinement",
    ):
        assert retired not in readme, f"README still advertises the retired preview limitation: {retired!r}"


def main() -> None:
    test_manifest_and_translations()
    test_schema_document_fixtures()
    test_coordinator_contract()
    test_reusable_pairing_catalog_contract()
    test_renderer_crash_backoff_contract()
    test_coordinator_apply_serialization_contract()
    test_dynamic_pair_fingerprint_contract()
    test_capture_scene_freshness_contract()
    test_managed_library_ownership_contract()
    test_palette_inventory_contract()
    test_wallhaven_contract()
    test_bounded_fetch_contract()
    test_provider_thumbnail_helper_contract()
    test_provider_preview_panel_contract()
    test_renderer_static_contract()
    test_capture_helper_fallback_validation()
    test_renderer_supervisor()
    test_motionbgs_contract()
    test_ui_and_documentation_surface()
    print("Wall-in-One v0.6 offline contract passed.")


if __name__ == "__main__":
    main()
