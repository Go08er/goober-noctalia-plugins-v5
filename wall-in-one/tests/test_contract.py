#!/usr/bin/env python3
"""Offline contract gate for Wall-in-One 0.4.

The test deliberately avoids a compositor and the network.  It pins the
manifest/state protocols statically, runs each shell helper's local checks,
and exercises the renderer supervisor with disposable fake renderers so PID
ownership, FIFO cleanup, and exact argv remain observable.
"""

from __future__ import annotations

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
    assert manifest["version"] == "0.4.0"
    assert manifest["plugin_api"] == 17
    # curl gates only the optional MotionBGS adapter; core/local wallpaper
    # behavior and the direct website fallback must remain installable without it.
    assert manifest["dependencies"] == ["bash"]
    assert {entry["id"]: entry["entry"] for entry in manifest["service"]} == {
        "coordinator": "service.luau",
        "renderer": "renderer.luau",
        "motionbgs": "motionbgs.luau",
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
        "use_w_engine",
        "use_mpvpaper",
        "use_motionbgs",
        "use_extra_provider",
        "w_engine_backend",
        "mpvpaper_backend",
        "capture_directory",
        "video_directory",
        "auto_capture",
        "pair_static",
        "sync_colors",
        "color_scheme",
        "palette_output",
        "video_source",
        "manual_pair_file",
        "workshop_id",
        "workshop_directory",
        "scene_screenshot_delay",
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
        "cycle_interval_minutes",
        "cycle_order",
        "cycle_start_on_load",
        "motionbgs_download_directory",
        "motionbgs_quality",
        "motionbgs_result_limit",
        "motionbgs_cache_minutes",
        "motionbgs_max_download_mb",
    }
    assert required <= settings.keys(), sorted(required - settings.keys())
    for key in ("w_engine_backend", "mpvpaper_backend"):
        assert settings[key]["default"] == "auto"
        assert [item["value"] for item in settings[key]["options"]] == [
            "auto",
            "external",
            "internal",
        ]
    assert settings["sync_colors"]["default"] is False
    assert settings["cycle_start_on_load"]["default"] is False
    assert (settings["cycle_interval_minutes"]["min"], settings["cycle_interval_minutes"]["max"]) == (
        1,
        43200,
    )
    assert settings["motionbgs_quality"]["default"] == "hd"
    assert [item["value"] for item in settings["motionbgs_quality"]["options"]] == ["hd", "4k"]
    for key, default, minimum, maximum in (
        ("motionbgs_result_limit", 24, 1, 24),
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


def test_coordinator_contract() -> None:
    service = text("service.luau")
    require_all(
        service,
        (
            "local CONFIG_SCHEMA = 2",
            "local RUNTIME_SCHEMA = 3",
            "local MAX_STORAGE_BYTES = 8 * 1024 * 1024",
            "local MAX_RUNTIME_OUTPUTS = 64",
            "local MAX_PAIR_REGISTRY_ENTRIES = 1024",
            "local MAX_PERSISTED_PATH_BYTES = 4096",
            'local RENDERER_COMMAND_KEY = "wall_in_one_renderer_command_v1"',
            'local RENDERER_STATUS_KEY = "wall_in_one_renderer_status_v1"',
            "schema ~= 1 and schema ~= CONFIG_SCHEMA",
            "local reels = if schema == 1 then {} else normalizedReels(candidate.reels)",
            "schema ~= 1 and schema ~= 2 and schema ~= RUNTIME_SCHEMA",
            "local function normalizedPair(candidate)",
            "local function normalizedPairMap(candidate, maximumEntries, registry)",
            "local function normalizedCycles(candidate)",
            "local function normalizedLastCapture(candidate)",
            "local pairRegistry = normalizedPairMap(",
            "MAX_PAIR_REGISTRY_ENTRIES",
            "if pairsState == nil or pairRegistry == nil or cycles == nil or lastCapture == nil then",
            'noctalia.tr("errors.runtime_nested")',
            "providers = {}",
            "pair_registry = pairRegistry",
            "cycles = cycles",
            'atomicWrite("config.json", nextConfig)',
            'atomicWrite("runtime.json", runtime)',
            'local backupTemporary = backup .. ".tmp"',
            "runtime.pair_registry[tostring(dynamicId)]",
            "config.reels[output]",
            "runtime.cycles[output]",
            "local stillPath = tostring(candidate.still_path or \"\")",
            "#stillPath > MAX_PERSISTED_PATH_BYTES",
            'or stillPath:sub(1, 1) ~= "/"',
            'or stillPath:find("[%c]")',
            "still_path = stillPath",
            'if (entry.kind == "video" or entry.kind == "workshop") and entry.still_path == "" then',
            "entry.still_path = currentPath",
            'event == "cycle-start" or event == "cycle-stop"',
            'event == "cycle-pause" or event == "cycle-resume"',
            'event == "cycle-next" or event == "cycle-previous" or event == "cycle-random"',
            'kind == "cycle_options"',
            'kind == "cycle_add_entry"',
            'kind == "cycle_remove_entry"',
            "next_due",
            "history",
            "bag",
            "local MAX_LIBRARY_CANDIDATES = 1024",
            "local LIBRARY_SCAN_BATCH = 4",
            "local function stepLibraryScan()",
            "local budget = LIBRARY_SCAN_BATCH",
            "if stepLibraryScan() then",
            "for index = 1, math.min(#entries, MAX_LIBRARY_CANDIDATES) do",
            "local workshopNamesExamined = 0",
            "workshopNamesExamined += 1",
            "if workshopNamesExamined >= MAX_LIBRARY_CANDIDATES then",
            "#scan.videos >= MAX_REEL_ENTRIES",
            "#scan.workshops >= MAX_REEL_ENTRIES",
            "local captureQueued = {}",
            "local adapterCaptureQueued = {}",
            "local activeCaptureRequests = {}",
            "local backendGeneration = { w_engine = 0, mpvpaper = 0 }",
        ),
        "coordinator persistence/scheduler contract",
    )
    assert service.count("budget -= 1") >= 2

    target_output = service[
        service.index("local function targetOutput") : service.index("local function settingBool")
    ]
    require_all(
        target_output,
        (
            'if candidate ~= nil and tostring(candidate) ~= "" then',
            "return knownOutputName(candidate)",
            "return knownOutputName(noctalia.focusedOutputName())",
        ),
        "explicit output fail-closed selection",
    )

    storage = service[
        service.index("local function atomicWrite") : service.index("local function loadStorage")
    ]
    require_all(
        storage,
        (
            "if #encoded + 1 > MAX_STORAGE_BYTES then",
            "(tonumber(info.size) or 0) > MAX_STORAGE_BYTES",
            'noctalia.tr("errors.storage_size"',
        ),
        "bounded storage read/write",
    )

    # Explicit internal selection and an enabled external plugin is a conflict,
    # and all branches refuse an internal apply unless it is both available and
    # selected.  Auto mode gives the already-enabled provider first refusal.
    policy = service[service.index("local function refreshBackendPolicy") : service.index("local function applyIntegrationPolicy")]
    require_all(
        policy,
        (
            "local ownershipKnown = providers.probe_ok == true",
            "local internalAvailable = allowed and ownershipKnown and rendererReady and commandAvailable",
            "elseif not ownershipKnown then",
            'return "none", false, false, false',
            'desired == "internal" and pluginEnabled',
            'desired == "external"',
            'return if pluginEnabled then "external" else "none"',
            'return if internalAvailable and not conflict then "internal" else "none"',
            'internalAvailable and not conflict',
            'elseif pluginEnabled then',
            'return "external", internalAvailable, false, false',
        ),
        "backend fail-closed policy",
    )
    internal_ready = service[
        service.index("local function internalBackendReady") : service.index("local function cachedPair")
    ]
    require_all(
        internal_ready,
        (
            "state.conflict == true",
            'state.effective_backend == "external"',
            'state.apply_available ~= true or state.effective_backend ~= "internal"',
        ),
        "internal apply boundary",
    )
    require_all(
        service,
        (
            'action = "start_w_engine"',
            'action = "start_mpvpaper"',
            'action = "pause"',
            'action = "resume"',
            'action = "stop"',
            "reconcileRendererOwnership",
            "invalidateCycleIntent",
            "local applyGeneration = {}",
            "applyGeneration[output] = (tonumber(applyGeneration[output]) or 0) + 1",
            "if tonumber(applyGeneration[output]) ~= applyToken then",
            'type(request.should_apply) == "function"',
            "pairIsCurrent = checked and current == true",
            "backendGeneration.w_engine += 1",
            "backendGeneration.mpvpaper += 1",
            "finishRendererPending",
            "rendererPending[command.nonce]",
            "tonumber(nextStatus.last_event_nonce)",
            "tonumber(cycleGeneration[selected]) ~= generation",
            'kind == "motionbgs_search"',
            'kind == "motionbgs_details"',
            'kind == "motionbgs_download"',
            'kind == "motionbgs_clear"',
            'noctalia.state.watch(MOTIONBGS_STATUS_KEY',
            'noctalia.state.watch(MOTIONBGS_RESULTS_KEY',
            "motionBgsStatus = nextStatus",
            "motionBgsResults = if type(nextResults) == \"table\"",
            'if settingBool("cycle_start_on_load", false) then',
            "state.running = false",
            "state.paused = false",
            "state.next_due = 0",
        ),
        "renderer/coordinator protocol",
    )

    # A capture may finish after a user action, output hotplug, or provider
    # observation changed.  It may still become a durable export, but pairing
    # and live-renderer start are gated by current output/provider generations.
    capture_finish = service[
        service.index("local function releaseCaptureSlot") : service.index("local function captureWorkshopFallback")
    ]
    require_all(
        capture_finish,
        (
            "local finalPath = tostring(request.pair_path or request.destination)",
            "pairIsCurrent = knownOutputName(request.output) ~= nil",
            'type(request.should_apply) == "function"',
            "pairIsCurrent = checked and current == true",
            "if request.pair and pairIsCurrent then",
            "local queued = captureQueued[key]",
            "local queuedAdapter = adapterCaptureQueued[key]",
            "local replaced = captureQueued[key]",
            'noctalia.tr("errors.capture_replaced")',
            "captureQueued[key] = request",
            "activeCaptureRequests[key] = nil",
            "activeCaptureRequests[key] = request",
        ),
        "capture completion/currentness and latest-wins queue",
    )
    adapter_capture = service[
        service.index("requestRenderedCapture = function") : service.index("local function receiveCaptureResult")
    ]
    require_all(
        adapter_capture,
        (
            "adapterCaptureQueued[key] = {",
            "providers.w_engine.allowed == true",
            "providers.w_engine.adapter_capture == true",
            'tostring(providers.w_engine.current[output] or "") == id',
            "knownOutputName(output) ~= nil",
        ),
        "cooperative adapter capture gate",
    )

    # Pairing is per output and color synchronization remains explicit opt-in.
    assert 'settingBool("sync_colors", false)' in service
    assert "runtime.pairs[key]" in service
    assert "noctalia.setWallpaper(output, path)" in service
    assert "setWallpaperEnabled(" not in service
    for forbidden in ("pgrep", "pkill", "killall", "setsid", "/proc/"):
        assert forbidden not in service, f"coordinator must not own processes: {forbidden}"

    paired_still = service[
        service.index("local function applyPairedStill") : service.index("local function releaseCaptureSlot")
    ]
    require_all(
        paired_still,
        (
            "if #registryEntries > MAX_PAIR_REGISTRY_ENTRIES then",
            "for index = 1, #registryEntries - MAX_PAIR_REGISTRY_ENTRIES do",
            "runtime.pair_registry[registryEntries[index].key] = nil",
            "if #outputPairs > MAX_RUNTIME_OUTPUTS then",
            "for index = 1, #outputPairs - MAX_RUNTIME_OUTPUTS do",
            "runtime.pairs[outputPairs[index].key] = nil",
        ),
        "bounded deterministic pair pruning",
    )

    directories = service[
        service.index("local function normalizedDirectory") : service.index(
            "local function configuredVideoSource"
        )
    ]
    require_all(
        directories,
        (
            'value == "/"',
            'value:find("/%./")',
            'value:match("/%.$")',
            'value:find("/%.%./")',
            'value:match("/%.%.$")',
            "normalizedDirectory(noctalia.wallpaperDirectory())",
            'dataDirectory .. "/captures"',
        ),
        "capture/video directory confinement",
    )

    static_apply = service[
        service.index("local function applyCycleEntry") : service.index("local advanceCycle")
    ]
    require_all(
        static_apply,
        (
            "local applyToken = (tonumber(applyGeneration[output]) or 0) + 1",
            "if tonumber(applyGeneration[output]) ~= applyToken then",
            "local function applyStatic(stopped)",
            "if stopped ~= true or (type(shouldStart) == \"function\" and shouldStart() ~= true) then",
            'queueRendererStop(output, function(stopped)',
            "applyVideoWithPair(output, entry.source, notifySuccess == true, onComplete, shouldStart, entry.still_path)",
            "applyWorkshopWithPair(output, entry.source, notifySuccess == true, onComplete, shouldStart, entry.still_path)",
            "invalidateCycleIntent(output, false)",
        ),
        "manual/cycle apply-generation barrier",
    )
    reconcile = service[
        service.index("reconcileRendererOwnership = function") : service.index(
            "local function internalBackendReady"
        )
    ]
    require_all(
        reconcile,
        (
            'local shouldStop = type(provider) ~= "table"',
            "knownOutputName(output) == nil",
            "provider.allowed ~= true",
            'provider.effective_backend ~= "internal"',
            "provider.apply_available ~= true",
            "provider.conflict == true",
            "invalidateCycleIntent(output, true)",
        ),
        "owned renderer reconciliation",
    )
    stop_queue = service[
        service.index("local function queueRendererStop") : service.index("invalidateCycleIntent = function")
    ]
    require_all(
        stop_queue,
        (
            'sendRendererCommand({ action = "stop", output = output }, function(ok, reason)',
            "rendererStopping[output] = nil",
            "onAcknowledged(ok == true, reason)",
            "rendererStopping[output] = true",
        ),
        "renderer stop retry guard",
    )

    selected_pair = service[
        service.index("local function selectedStaticPair") : service.index("local function startInternalVideo")
    ]
    require_all(
        selected_pair,
        (
            "local preferred = valid(preferredPath)",
            'return preferred, "selected-static"',
            'if provider == "manual" or provider == "noctalia" then',
        ),
        "explicit reel still selection",
    )
    video_apply = service[
        service.index("local function applyVideoWithPair") : service.index("local function applyWorkshopWithPair")
    ]
    workshop_apply = service[
        service.index("local function applyWorkshopWithPair") : service.index("local function reelForOutput")
    ]
    require_all(
        video_apply,
        (
            "local backendToken = backendGeneration.mpvpaper",
            "return backendGeneration.mpvpaper == backendToken",
            "and knownOutputName(output) ~= nil",
            "selectedStaticPair(output, preferredStillPath)",
        ),
        "mpvpaper backend generation barrier",
    )
    assert video_apply.index("selectedStaticPair(output, preferredStillPath)") < video_apply.index(
        "cachedPair(dynamicId)"
    )
    require_all(
        workshop_apply,
        (
            "local backendToken = backendGeneration.w_engine",
            "return backendGeneration.w_engine == backendToken",
            "and knownOutputName(output) ~= nil",
            "selectedStaticPair(output, preferredStillPath)",
        ),
        "W Engine backend generation barrier",
    )
    assert workshop_apply.index("selectedStaticPair(output, preferredStillPath)") < workshop_apply.index(
        "cachedPair(id)"
    )

    outputs_changed = service[
        service.index("function onOutputsChanged()") : service.index("function onIpc")
    ]
    require_all(
        outputs_changed,
        (
            "for output in pairs(owned) do",
            "for output in pairs(captureInFlight) do",
            "for output in pairs(applyGeneration) do",
            'if output ~= "all" and knownOutputName(output) == nil then',
            "invalidateCycleIntent(output, true)",
            "invalidateCycleIntent(output, false)",
        ),
        "output hotplug invalidation",
    )

    startup_cycle_policy = service[
        service.index('if settingBool("cycle_start_on_load", false) then') : service.index(
            "local previousAck = noctalia.state.get(COMMAND_ACK_KEY)"
        )
    ]
    require_all(
        startup_cycle_policy,
        (
            "state.running = true",
            "state.next_due = nowSeconds()",
            "else",
            "for output, value in pairs(runtime.cycles) do",
            "state.running = false",
            "state.paused = false",
            "state.next_due = 0",
            "persistRuntimeIfChanged(true)",
        ),
        "cycle start-on-load disarm policy",
    )

    advance_cycle = service[
        service.index("advanceCycle = function") : service.index("local function setCycleRunState")
    ]
    require_all(
        advance_cycle,
        (
            "if state.paused == true then",
            'setActionError(noctalia.tr("errors.cycle_paused"), "cycle")',
            "return false",
            "local index = selectCycleIndex(reel, state, direction or \"next\")",
        ),
        "paused cycle navigation rejection",
    )
    assert advance_cycle.index("if state.paused == true then") < advance_cycle.index(
        'local index = selectCycleIndex(reel, state, direction or "next")'
    )
    action_availability = service[
        service.index("local function actionAvailability") : service.index("local function runNativeSwitch")
    ]
    require_all(
        action_availability,
        (
            'if action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then',
            "if type(state) == \"table\" and state.paused == true then",
            'return false, noctalia.tr("errors.cycle_paused")',
        ),
        "paused scheduler control availability",
    )

    gif_paths = service[
        service.index("local function captureCurrentBacking") : service.index("local function actionAvailability")
    ]
    require_all(
        gif_paths,
        (
            'or extension == ".gif"',
            'if extension == ".gif" and noctalia.commandExists("ffmpeg") then',
            'or (extension == ".gif" and not noctalia.commandExists("ffmpeg"))',
            'destination, destinationError = captureDestination("manual", identity, output, ".png")',
            'mode = if extension == ".gif" then "image" else "copy"',
            "pair_path = pairPath",
            "return tonumber(applyGeneration[output]) == pairToken and knownOutputName(output) ~= nil",
        ),
        "GIF export/manual-pair persistence",
    )

    staging_cleanup = service[
        service.index("local function cleanupOwnedStaging") : service.index("local function workshopFallbackSpec")
    ]
    require_all(
        staging_cleanup,
        (
            "for index = 1, math.min(#entries, 512) do",
            'name:match("^capture%-%w[%w%-]*%.png$")',
            'noctalia.removeFile(directory .. "/" .. name)',
        ),
        "bounded owned-staging cleanup",
    )
    assert "\ncleanupOwnedStaging()\nloadStorage()\n" in service

    dispatch = service[
        service.index("local function dispatchAction") : service.index("local function setMapping")
    ]
    assert dispatch.index('if action == "motionbgs_open"') < dispatch.index(
        "if not configValid or not runtimeValid"
    )
    motion_send = service[
        service.index("local function sendMotionBgsCommand") : service.index(
            "local function runWEngineControl"
        )
    ]
    assert "not configValid or not runtimeValid" in motion_send

    helper = text("scripts/capture-still")
    require_all(
        helper,
        (
            "<video|image|copy>",
            'ffmpeg -nostdin -y -loglevel error -ss "$second"',
            'tmpdir="$destination_dir"',
            ".part",
            "validate_image_signature",
            "validate_webp_structure",
            "declared + 8 == file_size",
            "offset == file_size && image_chunk == 1",
            "AVIF's ISO-BMFF box graph cannot be established from a short magic",
            "????????6674797061766966* | ????????6674797061766973*) return 1",
            'mv -f -- "$temporary" "$destination"',
        ),
        "capture helper",
    )
    for forbidden in ("linux-wallpaperengine", "mpvpaper", "pkill", "setsid"):
        assert forbidden not in helper

    on_exit = service[service.index("function onExit(_signal, _reason)") :]
    require_all(
        on_exit,
        (
            "for _, request in pairs(pendingAdapterCaptures) do",
            "for _, request in pairs(captureQueued) do",
            "for _, request in pairs(activeCaptureRequests) do",
            "noctalia.removeFile(request.staging_path)",
        ),
        "capture staging exit cleanup",
    )


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
            'runtime:gsub("/+$", "") .. "/noctalia-wall-in-one"',
            'dataDirectory:gsub("/+$", "") .. "/runtime"',
            '"exec bash " .. shellQuote(helper)',
            "noctalia.runStream(command, handleSupervisorLine)",
            "for _, output in ipairs(noctalia.outputs())",
            'if id:match("^%d+$") == nil or #id > 24',
            'autoPauseMode ~= "FULL" and autoPauseMode ~= "MAX"',
            "noctalia.fileInfo(video)",
            '"WIO1"',
            '"start_w_engine"',
            '"start_mpvpaper"',
            "noctalia.state.watch(COMMAND_KEY",
            "dd conv=nocreat,notrunc oflag=nofollow",
        ),
        "renderer service",
    )
    # A single cancellable stream owns the supervisor.  Cleanup must stay in
    # that process tree instead of launching an uncancellable teardown job.
    assert renderer.count("noctalia.runStream(") == 1
    assert "function onExit" not in renderer or "noctalia.runAsync" not in renderer[renderer.index("function onExit") :]

    require_all(
        supervisor,
        (
            "mkfifo -m 600",
            'exec 3<>"$fifo_path"',
            "declare -A child_pid=()",
            'local pid=${child_pid[$output]:-}',
            'kill -TERM "$pid"',
            'kill -KILL "$pid"',
            'kill -STOP "$pid"',
            'kill -CONT "$pid"',
            'wait "$pid"',
            'rm -f -- "$fifo_path"',
            "trap cleanup EXIT",
            "--layer bottom",
            "local options='loop-file=inf panscan=1.0 terminal=no'",
            "args+=(--auto-pause \"$auto_pause_mode\" --auto-mode)",
            'options+=" $extra_options"',
            "10#$nonce <= last_nonce",
            "start_w_engine has invalid fields",
            "start_mpvpaper has invalid fields",
        ),
        "renderer supervisor",
    )
    executable_supervisor = "\n".join(
        line for line in supervisor.splitlines() if not line.lstrip().startswith("#")
    )
    for forbidden in ("pgrep", "pkill", "killall", "setsid", "systemd-run"):
        assert forbidden not in executable_supervisor, (
            f"renderer supervisor uses name/detached ownership: {forbidden}"
        )


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
case ${0##*/} in
  linux-wallpaperengine) log=${WIO_ENGINE_LOG:?} ;;
  mpvpaper) log=${WIO_MPV_LOG:?} ;;
  *) exit 64 ;;
esac
{
  printf '%s\\0' "$$"
  printf '%s\\0' "$@"
} >"$log"
trap 'exit 0' TERM INT HUP
while :; do sleep 0.1; done
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
        video = temp / "fixture video.mp4"
        video.write_bytes(b"fixture")
        engine_log = temp / "engine.args"
        mpv_log = temp / "mpv.args"
        fifo = temp / "runtime" / "commands.fifo"
        environment = os.environ.copy()
        environment.update(
            PATH=f"{bin_dir}:{environment.get('PATH', '')}",
            WIO_ENGINE_LOG=str(engine_log),
            WIO_MPV_LOG=str(mpv_log),
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
        mpv_pid = 0
        try:
            event("ready", 0)
            assert stat.S_IMODE(fifo.stat().st_mode) == 0o600

            send(
                [
                    "WIO1",
                    1,
                    "start_w_engine",
                    "HEADLESS-1",
                    "431960001",
                    60,
                    15,
                    "fill",
                    "border",
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
                "431960001",
                "--scaling",
                "fill",
                "--clamp",
                "border",
                "--layer",
                "bottom",
                "--fps",
                "60",
                "--volume",
                "15",
                "--noautomute",
                "--no-audio-processing",
                "--disable-particles",
                "--disable-mouse",
                "--disable-parallax",
                "--fullscreen-pause-only-active",
            ]

            send(["WIO1", 2, "start_mpvpaper", "HEADLESS-1", video, 1, 1, 1, "FULL", "Vkeep-open=yes"])
            event("started", 2)
            _wait_until(mpv_log.exists, "fake mpvpaper was not launched")
            _wait_until(lambda: not _alive(engine_pid), "replacing an output did not stop the exact old child")
            mpv_args = _nul_fields(mpv_log)
            mpv_pid = int(mpv_args[0])
            assert _alive(mpv_pid)
            assert mpv_args[1:6] == ["--layer", "bottom", "--auto-pause", "FULL", "--auto-mode"]
            assert mpv_args[-2:] == ["HEADLESS-1", str(video)]
            option_index = mpv_args.index("-o")
            options = mpv_args[option_index + 1]
            for option in (
                "loop-file=inf",
                "panscan=1.0",
                "terminal=no",
                "no-audio",
                "hwdec=auto",
                "input-ipc-server=",
                "keep-open=yes",
            ):
                assert option in options

            send(["WIO1", 3, "pause", "HEADLESS-1"])
            event("paused", 3)
            _wait_until(
                lambda: Path(f"/proc/{mpv_pid}/status").read_text().split("State:", 1)[1].lstrip().startswith("T"),
                "pause did not signal the owned child",
            )
            send(["WIO1", 4, "resume", "HEADLESS-1"])
            event("resumed", 4)
            _wait_until(
                lambda: not Path(f"/proc/{mpv_pid}/status").read_text().split("State:", 1)[1].lstrip().startswith("T"),
                "resume did not signal the owned child",
            )

            send(["WIO1", 4, "stop", "HEADLESS-1"])
            event("ignored", 4)
            assert _alive(mpv_pid), "a stale nonce affected renderer ownership"
            assert _alive(sentinel.pid), "renderer command affected an unrelated process"

            send(["WIO1", 5, "stop", "HEADLESS-1"])
            event("stopped", 5)
            _wait_until(lambda: not _alive(mpv_pid), "stop did not reap the exact owned child")
            assert _alive(sentinel.pid), "stop affected an unrelated process"

            send(["WIO1", 6, "start_mpvpaper", "HEADLESS-1", video, 1, 0, 1, "MAX", "E"])
            event("started", 6)
            _wait_until(lambda: _nul_fields(mpv_log)[0] != str(mpv_pid), "replacement child was not launched")
            mpv_pid = int(_nul_fields(mpv_log)[0])
            supervisor.terminate()
            supervisor.wait(timeout=6)
            _wait_until(lambda: not _alive(mpv_pid), "supervisor exit leaked an owned renderer")
            _wait_until(lambda: not fifo.exists(), "supervisor exit leaked its FIFO")
            assert _alive(sentinel.pid), "supervisor cleanup affected an unrelated process"
        finally:
            if supervisor.poll() is None:
                supervisor.terminate()
                try:
                    supervisor.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    supervisor.kill()
                    supervisor.wait(timeout=3)
            for pid in (engine_pid, mpv_pid):
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
            'local COMMAND_KEY = "wall_in_one_motionbgs_command_v1"',
            'local COMMAND_ACK_KEY = "wall_in_one_motionbgs_command_ack_v1"',
            'local STATUS_KEY = "wall_in_one_motionbgs_status_v1"',
            'local RESULTS_KEY = "wall_in_one_motionbgs_results_v1"',
            "local MAX_RESULTS = 24",
            "local MAX_QUEUE = 8",
            "local MAX_CACHE_SEARCHES = 8",
            "local MAX_CACHE_DETAILS = 48",
            'settingInt("motionbgs_result_limit", MAX_RESULTS, 1, MAX_RESULTS)',
            'settingInt("motionbgs_cache_minutes", 30, 5, 1440)',
            'settingInt("motionbgs_max_download_mb", 256, 16, 512)',
            'settingString("motionbgs_download_directory", "")',
            'settingString("video_directory", "")',
            'quality == "4k"',
            'kind == "site-markup" or kind == "challenge"',
            "challengePage",
            "parseSearchHtml",
            "parseDetailsHtml",
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
            ".motionbgs-body.",
            ".motionbgs.json",
            'mv -f -- "$body" "$output"',
            'mv -f -- "$sidecar_tmp" "$sidecar"',
        ),
        "MotionBGS helper",
    )
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
        ("cycle_start", "cycle_stop", "cycle_next", "cycle_previous", "cycle_random"),
        "panel scheduler UI",
    )
    readme = text("README.md").lower()
    for phrase in (
        "0.4",
        "internal",
        "external",
        "mpvpaper",
        "wallpaper engine",
        "motionbgs",
        "scheduler",
        "schema 2",
        "schema 3",
    ):
        assert phrase in readme, f"README does not document {phrase!r}"


def main() -> None:
    test_manifest_and_translations()
    test_coordinator_contract()
    test_renderer_static_contract()
    test_capture_helper_fallback_validation()
    test_renderer_supervisor()
    test_motionbgs_contract()
    test_ui_and_documentation_surface()
    print("Wall-in-One v0.4 offline contract passed.")


if __name__ == "__main__":
    main()
