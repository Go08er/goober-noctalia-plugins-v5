"""Small offline contract test for the Wall-in-One 0.1 thin client."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Any

import tomllib

ROOT = Path(__file__).resolve().parents[1]


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def flatten_strings(value: Any, prefix: str = "") -> dict[str, str]:
    if not isinstance(value, dict):
        raise TypeError(f"translation node {prefix or '<root>'} is not an object")
    flattened: dict[str, str] = {}
    for key, child in value.items():
        assert isinstance(key, str) and re.fullmatch(r"[a-z0-9][a-z0-9_-]*", key), key
        dotted = f"{prefix}.{key}" if prefix else key
        if isinstance(child, dict):
            flattened.update(flatten_strings(child, dotted))
        else:
            assert isinstance(child, str) and child.strip(), (
                f"invalid translation: {dotted}"
            )
            flattened[dotted] = child
    return flattened


def discover_tool(name: str) -> Path | None:
    candidates: list[Path] = []
    configured = os.environ.get(name.upper().replace("-", "_"))
    if configured:
        candidates.append(Path(configured))
    found = shutil.which(name)
    if found:
        candidates.append(Path(found))
    for sibling_name in ("luau", "luau-compile"):
        sibling = shutil.which(sibling_name)
        if sibling:
            candidates.append(Path(sibling).with_name(name))
    store = Path("/nix/store")
    if store.is_dir():
        candidates.extend(sorted(store.glob(f"*-luau-*/bin/{name}"), reverse=True))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


class ThinClientContract(unittest.TestCase):
    def test_manifest_translations_and_entries(self) -> None:
        manifest_source = read("plugin.toml")
        manifest = tomllib.loads(manifest_source)
        self.assertEqual(manifest["id"], "goober/wall-in-one")
        self.assertEqual(manifest["name"], "Wall-in-One")
        self.assertEqual(manifest["version"], "0.1.2")
        self.assertEqual(manifest["plugin_api"], 17)
        self.assertEqual(manifest["dependencies"], ["wall-in-one"])

        expected = {
            "service": [("control", "service.luau")],
            "widget": [("wall-in-one", "widget.luau")],
            "panel": [("controls", "panel.luau")],
        }
        declared: set[str] = set()
        for entry_type, entries in expected.items():
            actual = [(item["id"], item["entry"]) for item in manifest[entry_type]]
            self.assertEqual(actual, entries)
            for _entry_id, relative_name in entries:
                relative = Path(relative_name)
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                entry = ROOT / relative
                self.assertTrue(
                    entry.is_file(), f"missing {entry_type} entry: {relative_name}"
                )
                self.assertEqual(entry.resolve().parent, ROOT.resolve())
                self.assertTrue(read(relative_name).startswith("--!nonstrict\n"))
                declared.add(relative_name)
        self.assertEqual(declared, {path.name for path in ROOT.glob("*.luau")})

        translations = flatten_strings(
            json.loads(
                read("translations/en.json"), object_pairs_hook=reject_duplicate_keys
            )
        )
        referenced: set[str] = set(
            re.findall(
                r'(?:label_key|description_key)\s*=\s*"([^"]+)"', manifest_source
            )
        )
        for entry_name in declared:
            referenced.update(
                re.findall(
                    r'noctalia\.(?:tr|trp)\(\s*["\']([^"\']+)["\']', read(entry_name)
                )
            )
        # These keys are selected dynamically, so a literal tr() scan cannot
        # see them.
        referenced.update(
            {
                "panel.playback.pause",
                "panel.playback.paused",
                "panel.playback.play",
                "panel.playback.playing",
                "panel.playback.stopped",
                "panel.modes.app_default",
                "panel.modes.manual",
                "panel.modes.off",
                "panel.modes.on",
                "panel.modes.turn_off",
                "panel.modes.turn_on",
                "panel.playlists.empty",
                "panel.playlists.unavailable",
                "panel.schedule.following",
                "panel.schedule.manual",
            }
        )
        missing = referenced - translations.keys()
        self.assertFalse(missing, f"missing translations: {missing}")

        actions = manifest["widget"][0]["actions"]
        self.assertEqual(
            actions,
            {
                "left": "panel-toggle goober/wall-in-one:controls",
                "right": "panel-toggle goober/wall-in-one:controls",
            },
        )
        self.assertNotIn("shortcut", manifest)

    def test_service_launch_and_retry_contract_is_explicit(self) -> None:
        source = read("service.luau")
        self.assertEqual(source.count("noctalia.runAsync("), 4)

        begin = source[
            source.index("local function beginLaunch") : source.index(
                "local function finish"
            )
        ]
        direct = source[
            source.index("launchDirect = function") : source.index(
                "local function beginLaunch"
            )
        ]
        # Without a user unit, the standalone Rust runtime is what should idle
        # all session. Its wait mode is quiet before the first app-written
        # configuration appears; the old Python service is not a fallback
        # because it cannot publish the required atomic inventory.
        runtime = source[
            source.index("local function runtimeBinary") : source.index(
                "launchDirect = function"
            )
        ]
        self.assertIn('"wall-in-one-service"', runtime)
        self.assertIn("noctalia.fileExists(sibling)", runtime)
        self.assertIn('noctalia.commandExists("wall-in-one-service")', runtime)

        self.assertIn("local runtime = runtimeBinary(command)", direct)
        self.assertIn('shellQuote(runtime) .. " --wait-for-config"', direct)
        self.assertIn('noctalia.tr("state.missing_runtime")', direct)
        self.assertNotIn('shellQuote(command) .. " --service"', direct)
        self.assertIn('--service-startup-prepare', direct)
        self.assertIn('--check-config', direct)
        self.assertIn('local SYSTEMD_START = "systemctl --user start wall-in-one.service"', source)
        self.assertIn('configuredOverride() == "" and noctalia.commandExists("systemctl")', begin)
        self.assertIn(
            "startupStep(SYSTEMD_START, STARTUP_PREPARE_TIMEOUT_MS, function()", begin
        )
        self.assertIn("launchDirect(command)", begin)

        invoke = source[
            source.index("invoke = function(job)") : source.index("pump = function()")
        ]
        for fragment in (
            'if job.verb == "open-app" then',
            'table.insert(parts, "open")',
            "noctalia.runAsync(table.concat(parts, \" \"))",
            'local parts = { shellQuote(command) }',
            'if job.verb == "health-sync" then',
            'table.insert(parts, "--sync-runtime-health")',
            "table.insert(parts, shellQuote(job.argument))",
            'noctalia.runAsync(table.concat(parts, " "), function(result)',
            'if launching and job.verb == "status" then STARTUP_CALL_TIMEOUT_MS else CALL_TIMEOUT_MS',
        ):
            self.assertIn(fragment, invoke)

        constants = {
            name: int(value)
            for name, value in re.findall(
                r"local (CALL_TIMEOUT_MS|STARTUP_CALL_TIMEOUT_MS|SYSTEMD_QUERY_TIMEOUT_MS|STARTUP_POLL_MS|"
                r"STARTUP_TIMEOUT_SECONDS|QUEUE_LIMIT) = (\d+)",
                source,
            )
        }
        self.assertEqual(
            constants,
            {
                "CALL_TIMEOUT_MS": 55000,
                "STARTUP_CALL_TIMEOUT_MS": 1500,
                "SYSTEMD_QUERY_TIMEOUT_MS": 3000,
                "STARTUP_POLL_MS": 250,
                "STARTUP_TIMEOUT_SECONDS": 60,
                "QUEUE_LIMIT": 8,
            },
        )
        self.assertLessEqual(
            constants["STARTUP_POLL_MS"], constants["STARTUP_CALL_TIMEOUT_MS"]
        )
        self.assertLess(
            constants["STARTUP_CALL_TIMEOUT_MS"], constants["CALL_TIMEOUT_MS"]
        )
        self.assertIn("startupDeadline = os.time() + STARTUP_TIMEOUT_SECONDS", begin)
        self.assertIn("if os.time() >= startupDeadline then", source)
        self.assertIn("if #queue >= QUEUE_LIMIT then", source)
        self.assertIn(
            "noctalia.setUpdateInterval(if launching then STARTUP_POLL_MS else configuredIntervalMs())",
            source,
        )
        self.assertIn(
            'math.max(5, math.min(300, tonumber(cfg("refresh_interval_seconds")) or 15))',
            source,
        )
        self.assertTrue(source.rstrip().endswith('enqueue("status", nil, true)'))

        panel = read("panel.luau")
        for verb in (
            "playlist-use",
            "schedule-follow",
            "previous",
            "toggle",
            "next",
            "random",
            "stop",
            "shuffle",
            "cycle",
            "open-app",
        ):
            self.assertIn(f'"{verb}"', panel)
        for authoring_verb in (
            'send("playlists"',
            'send("schedule"',
            'send("displays"',
            'send("display-assign"',
            'send("display-clear"',
            'send("dynamics"',
            'send("reload-palette"',
        ):
            self.assertNotIn(authoring_verb, panel)
        self.assertIn('send("open-app", "schedules")', panel)
        self.assertIn('send("open-app", "displays")', panel)
        self.assertIn('glyph = "dice"', panel)
        self.assertIn('send("stop", nil)', panel)
        self.assertIn('send("cycle", "default")', panel)
        self.assertNotIn("panel.playback.shuffle_on", panel)
        self.assertNotIn("panel.playback.shuffle_off", panel)

        # Inventory comes only from the same decoded status snapshot as the
        # playback state. Runtime listing and display-mutation verbs do not
        # exist and must never be sent while the GUI is closed.
        self.assertIn("noctalia.json.decode(line)", source)
        for obsolete in (
            "publishPlaylists",
            "publishSchedule",
            "publishDisplays",
            'playlists = true',
            'schedule = true',
            'displays = true',
            '["display-assign"] = true',
            '["display-clear"] = true',
        ):
            self.assertNotIn(obsolete, source)

    def test_luau_entries_compile_when_compiler_is_available(self) -> None:
        compiler = discover_tool("luau-compile")
        if compiler is None:
            self.skipTest("luau-compile is not discoverable")
        for entry in sorted(ROOT.glob("*.luau")):
            completed = subprocess.run(
                [str(compiler), "--null", str(entry)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                check=False,
            )
            self.assertEqual(
                completed.returncode, 0, f"{entry.name}:\n{completed.stdout}"
            )

    def test_service_process_shapes_and_bounds_in_mock_host(self) -> None:
        runtime = discover_tool("luau")
        if runtime is None:
            self.skipTest("standalone luau runtime is not discoverable")

        prefix = r"""
            local calls = {}
            local intervals = {}
            local states = {}
            local watchers = {}
            local now = 100
            local configuredBinary = "/tmp/wall in ' one/wall-in-one"
            local configuredRuntime = "/tmp/wall in ' one/wall-in-one-service"
            local systemctlAvailable = false
            local fixtureStatus = {
                status_version = 2,
                playlist_id = "day",
                playlist = "Day set",
                source = "schedule",
                entry_id = "morning",
                kind = "still",
                still = "/tmp/morning.png",
                motion_active = false,
                playback_state = "playing",
                paused = false,
                stopped = false,
                shuffle = true,
                cycle_enabled = true,
                cycle_default = false,
                cycle_source = "manual",
                last_error = "",
                taboo_entries = {},
                playlists = {
                    { id = "day", name = "Day set", entries = 4, active = true },
                    { id = "night", name = "Night", entries = 2, active = false },
                },
                schedule = {
                    following = true,
                    playlist_id = "day",
                    playlist = "Day set",
                    rule_id = "r1",
                },
                schedules = {
                    {
                        id = "r1",
                        playlist_id = "day",
                        playlist = "Day set",
                        months = {},
                        weekdays = {},
                        start = "06:00",
                        ["end"] = "22:00",
                        enabled = true,
                        selected = true,
                        in_force = true,
                    },
                },
                displays = {
                    {
                        connector = "eDP-1",
                        assigned_playlist_id = "day",
                        assigned_playlist = "Day set",
                        playlist_id = "day",
                        playlist = "Day set",
                        entry_id = "morning",
                        kind = "still",
                        still = "/tmp/morning.png",
                        motion_active = false,
                    },
                },
            }
            local os = { time = function() return now end }
            local noctalia = {
                getConfig = function(key)
                    if key == "binary_path" then return configuredBinary end
                    if key == "refresh_interval_seconds" then return 15 end
                    return nil
                end,
                string = {
                    trim = function(value)
                        return string.match(tostring(value), "^%s*(.-)%s*$")
                    end,
                },
                expandPath = function(path) return path end,
                fileExists = function(path)
                    return path == configuredBinary or path == configuredRuntime
                end,
                commandExists = function(name)
                    if name == "systemctl" then return systemctlAvailable end
                    if name == "wall-in-one" then return configuredBinary == "" end
                    if name == "wall-in-one-service" then return configuredBinary == "" end
                    return false
                end,
                json = {
                    decode = function(raw)
                        if raw == "RUNTIME_STATUS" then return fixtureStatus end
                        return nil, "fixture rejected malformed JSON"
                    end,
                },
                setUpdateInterval = function(value) table.insert(intervals, value) end,
                runAsync = function(command, callback, timeout)
                    table.insert(calls, { command = command, callback = callback, timeout = timeout })
                    return true
                end,
                tr = function(key) return key end,
                log = function(_message) end,
                state = {
                    get = function(key) return states[key] end,
                    set = function(key, value)
                        states[key] = value
                        if watchers[key] ~= nil then watchers[key](value) end
                    end,
                    watch = function(key, callback) watchers[key] = callback end,
                },
            }
        """
        checks = r"""
            local quotedBinary = "'/tmp/wall in '\"'\"' one/wall-in-one'"
            local quotedRuntime = "'/tmp/wall in '\"'\"' one/wall-in-one-service'"
            local function complete(index, result)
                assert(type(calls[index].callback) == "function", "call has no completion callback")
                calls[index].callback(result)
            end

            -- The plugin probes first and starts nothing when an existing
            -- service answers. Exit 3 is the only path that launches one.
            assert(#calls == 1 and calls[1].command == quotedBinary .. " ctl status")
            assert(calls[1].timeout == 55000)
            complete(1, { timedOut = false, exitCode = 3, stdout = "", stderr = "" })
            assert(#calls == 2 and calls[2].command == quotedBinary .. " --service-startup-prepare")
            complete(2, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            assert(#calls == 3 and calls[3].command == quotedRuntime .. " --check-config")
            complete(3, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            -- The remaining assertions concern the runtime client; discard
            -- the two verified preparation calls from its call history.
            table.remove(calls, 2)
            table.remove(calls, 2)
            assert(#calls == 3, "absent service did not launch and start readiness polling")
            assert(calls[2].command == quotedRuntime .. " --wait-for-config", calls[2].command)
            assert(calls[2].callback == nil and calls[2].timeout == nil)
            assert(calls[3].command == quotedBinary .. " ctl status", calls[3].command)
            assert(calls[3].timeout == 1500 and type(calls[3].callback) == "function")
            assert(startupDeadline == 160 and intervals[#intervals] == 250)

            complete(3, {
                timedOut = false,
                exitCode = 0,
                stdout = "RUNTIME_STATUS",
                stderr = "",
            })
            assert(states[STATE_KEY].running == true and states[STATE_KEY].launching == false)
            assert(states[STATE_KEY].playlist == "Day set" and states[STATE_KEY].entryId == "morning")
            assert(states[STATE_KEY].shuffle == true and states[STATE_KEY].cycleEnabled == true)
            assert(states[STATE_KEY].playbackState == "playing" and states[STATE_KEY].stopped == false)
            assert(states[STATE_KEY].cycleDefault == false and states[STATE_KEY].cycleSource == "manual")
            assert(intervals[#intervals] == 15000, "successful startup did not restore resting polling")

            -- That one status reply also publishes the complete menu. No
            -- authoring process or listing round trip exists in this test.
            local menu = states[MENU_KEY]
            assert(#menu.playlists == 2 and menu.playlists[1].name == "Day set")
            assert(menu.playlists[1].active == true and menu.playlists[1].entries == 4)
            assert(menu.schedule.following == true and menu.schedule.playlist == "Day set")
            assert(menu.schedules[1].id == "r1" and menu.schedules[1].in_force == true)
            assert(menu.displays[1].connector == "eDP-1" and menu.displays[1].playlist == "Day set")
            assert(#calls == 3, "status inventory unexpectedly triggered another control call")

            -- A session-only health record schedules one serialized durable
            -- hand-off. A durable record does not recursively reschedule it.
            fixtureStatus.taboo_entries = { { durable = false } }
            publishStatus("RUNTIME_STATUS")
            assert(calls[4].command == quotedBinary .. " --sync-runtime-health")
            assert(calls[4].timeout == 55000)
            fixtureStatus.taboo_entries = { { durable = true } }
            complete(4, { timedOut = false, exitCode = 0, stdout = "saved", stderr = "" })
            assert(calls[5].command == quotedBinary .. " ctl status")
            complete(5, { timedOut = false, exitCode = 0, stdout = "RUNTIME_STATUS", stderr = "" })
            assert(#calls == 5, "durable health recursively scheduled another sync")

            fixtureStatus.status_version = 99
            publishStatus("RUNTIME_STATUS")
            assert(states[STATE_KEY].running == false)
            assert(string.find(states[STATE_KEY].error, "invalid_status", 1, true) ~= nil)
            fixtureStatus.status_version = 2
            fixtureStatus.taboo_entries = {}
            publishStatus("RUNTIME_STATUS")

            fixtureStatus.power_source = "battery"
            fixtureStatus.power_available = true
            fixtureStatus.stop_animations_on_battery = true
            fixtureStatus.animations_inhibited = true
            fixtureStatus.animation_inhibition_reason = "battery"
            publishStatus("RUNTIME_STATUS")
            assert(states[STATE_KEY].powerSource == "battery" and states[STATE_KEY].powerAvailable)
            assert(states[STATE_KEY].stopAnimationsOnBattery and states[STATE_KEY].animationsInhibited)
            assert(states[STATE_KEY].animationInhibitionReason == "battery")
            assert(states[STATE_KEY].playbackState == "playing", "power state replaced manual playback")

            -- Arguments and a configured path containing spaces and quotes are
            -- independently shell-quoted; the graphical app is detached.
            onIpc("playlist-use", { argument = "Night's set" })
            assert(calls[6].command == quotedBinary .. " ctl playlist-use 'Night'\"'\"'s set'", calls[6].command)
            assert(calls[6].timeout == 55000 and type(calls[6].callback) == "function")
            complete(6, { timedOut = false, exitCode = 0, stdout = "playing Night's set", stderr = "" })
            assert(calls[7].command == quotedBinary .. " ctl status")

            -- Startup actions are replayed only after an accepted status-v2
            -- handshake. A newer schema is presentation-incompatible and
            -- must fail closed instead of sending the captured mutation.
            table.clear(queue)
            busy = false
            calls = {}
            fixtureStatus.status_version = 99
            beginLaunch({ verb = "next", argument = nil })
            complete(1, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            complete(2, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            table.remove(calls, 1)
            table.remove(calls, 1)
            assert(#calls == 2 and calls[2].command == quotedBinary .. " ctl status")
            complete(2, { timedOut = false, exitCode = 0, stdout = "RUNTIME_STATUS", stderr = "" })
            assert(#calls == 2, "incompatible status replayed a captured action")
            assert(states[STATE_KEY].running == false)
            fixtureStatus.status_version = 2

            -- Clear the post-change refresh chain before checking presentation.
            table.clear(queue)
            busy = false
            calls = {}
            onIpc("open-app", nil)
            assert(#calls == 1 and calls[1].command == quotedBinary)
            assert(calls[1].callback == nil and calls[1].timeout == nil)
            calls = {}
            onIpc("open-app", { argument = "schedules" })
            assert(#calls == 1 and calls[1].command == quotedBinary .. " ctl open 'schedules'")

            -- Only an explicitly absent unit permits the direct fallback.
            calls = {}
            table.clear(queue)
            busy = false
            clearLaunch()
            configuredBinary = ""
            systemctlAvailable = true
            onIpc("launch", nil)
            assert(#calls == 1 and calls[1].command == "systemctl --user show wall-in-one.service --property=LoadState --value")
            assert(calls[1].timeout == 3000 and type(calls[1].callback) == "function")
            complete(1, { timedOut = false, exitCode = 0, stdout = "not-found\n", stderr = "" })
            assert(calls[2].command == "'wall-in-one' --service-startup-prepare")
            complete(2, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            assert(calls[3].command == "'wall-in-one-service' --check-config")
            complete(3, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            assert(#calls == 5)
            assert(calls[4].command == "'wall-in-one-service' --wait-for-config" and calls[4].callback == nil)
            assert(calls[5].command == "'wall-in-one' ctl status" and calls[5].timeout == 1500)

            -- Loaded-unit failures (including a still-running systemd start)
            -- preserve the boundary instead of spawning a detached runtime.
            for _, failure in ipairs({
                { timedOut = false, exitCode = 1, stdout = "", stderr = "migration blocked" },
                { timedOut = true, exitCode = 124, stdout = "", stderr = "" },
            }) do
                calls = {}
                table.clear(queue)
                busy = false
                clearLaunch()
                onIpc("launch", nil)
                complete(1, { timedOut = false, exitCode = 0, stdout = "loaded\n", stderr = "" })
                assert(calls[2].command == "systemctl --user start wall-in-one.service")
                assert(calls[2].timeout == 55000)
                complete(2, failure)
                assert(#calls == 2, "failed systemd preflight spawned a detached runtime")
                assert(states[STATE_KEY].running == false and states[STATE_KEY].error ~= "")
                assert(#states[MENU_KEY].playlists == 0, "failed startup retained stale inventory")
            end

            -- A masked unit or failed load-state query is not an absent unit.
            for _, result in ipairs({
                { timedOut = false, exitCode = 0, stdout = "masked\n", stderr = "" },
                { timedOut = false, exitCode = 1, stdout = "", stderr = "no user bus" },
            }) do
                calls = {}
                clearLaunch()
                onIpc("launch", nil)
                complete(1, result)
                assert(#calls == 1 and states[STATE_KEY].error ~= "")
            end

            -- Direct migrations fail closed too, and Open app remains usable.
            calls = {}
            configuredBinary = "/tmp/wall in ' one/wall-in-one"
            clearLaunch()
            onIpc("launch", nil)
            assert(calls[1].command == quotedBinary .. " --service-startup-prepare")
            complete(1, { timedOut = false, exitCode = 1, stdout = "", stderr = "choose a library root" })
            assert(#calls == 1 and states[STATE_KEY].error == "choose a library root")
            onIpc("open-app", nil)
            assert(#calls == 2 and calls[2].command == quotedBinary and calls[2].callback == nil)

            calls = {}
            clearLaunch()
            onIpc("launch", nil)
            onIpc("open-app", nil)
            assert(#calls == 2 and calls[2].command == quotedBinary,
                "opening configuration waited behind startup preparation")
            complete(1, { timedOut = false, exitCode = 0, stdout = "", stderr = "" })
            assert(calls[3].command == quotedRuntime .. " --check-config")
            complete(3, { timedOut = false, exitCode = 78, stdout = "", stderr = "invalid runtime config" })
            assert(#calls == 3 and states[STATE_KEY].error == "invalid runtime config",
                "invalid runtime config launched a detached service")
        """

        with tempfile.TemporaryDirectory(
            prefix="wall-in-one-thin-client-"
        ) as temporary:
            harness = Path(temporary) / "service_harness.luau"
            harness.write_text(
                textwrap.dedent(prefix)
                + "\n"
                + read("service.luau")
                + "\n"
                + textwrap.dedent(checks),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [str(runtime), str(harness)],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stdout)

    def test_rendered_control_errors_and_battery_restrictions(self) -> None:
        runtime = discover_tool("luau")
        if runtime is None:
            self.skipTest("standalone luau runtime is not discoverable")
        prefix = r"""
            local states = {
                wall_in_one_state = { running = false, error = "choose a library root" },
                wall_in_one_menu = { playlists = {}, displays = {}, schedules = {}, schedule = {} },
            }
            local watches, tree, tooltipText = {}, nil, ""
            local noctalia = {
                tr = function(key) return key end,
                getConfig = function(key)
                    if key == "color" then return "primary" end
                    if key == "stopped_color" then return "on_surface_variant" end
                    return nil
                end,
                state = {
                    get = function(key) return states[key] end,
                    set = function(key, value) states[key] = value end,
                    watch = function(key, callback) watches[key] = callback end,
                },
                setUpdateInterval = function(_value) end,
            }
            local ui = setmetatable({}, { __index = function(_table, _key)
                return function(properties, children) return { props = properties, children = children } end
            end })
            local panel = { render = function(value) tree = value end }
            local barWidget = setmetatable({
                setTooltip = function(value) tooltipText = value end,
            }, { __index = function() return function() end end })
            local function hasText(node, expected)
                if type(node) ~= "table" then return false end
                if type(node.props) == "table" and node.props.text == expected then return true end
                for _, child in ipairs(node.children or {}) do
                    if hasText(child, expected) then return true end
                end
                return false
            end
        """
        panel_checks = r"""
            assert(hasText(tree, "choose a library root"), "panel hid the actionable control failure")
            local current = {
                running = true, playlist = "Day", playbackState = "paused", source = "manual",
                animationsInhibited = true, animationInhibitionReason = "battery",
            }
            states.wall_in_one_state = current
            watches.wall_in_one_state(current)
            watches.wall_in_one_menu(states.wall_in_one_menu)
            assert(hasText(tree, "panel.power.on_battery"))
            assert(current.playbackState == "paused", "power presentation changed manual playback")
            current.animationInhibitionReason = "power-unavailable"
            watches.wall_in_one_state(current)
            watches.wall_in_one_menu(states.wall_in_one_menu)
            assert(hasText(tree, "panel.power.unavailable"))
            current.animationsInhibited = false
            watches.wall_in_one_state(current)
            watches.wall_in_one_menu(states.wall_in_one_menu)
            assert(not hasText(tree, "panel.power.unavailable"))
        """
        widget_checks = r"""
            assert(string.find(tooltipText, "choose a library root", 1, true))
            local current = {
                running = true, showing = "Day", playbackState = "paused", source = "manual",
                animationsInhibited = true, animationInhibitionReason = "battery",
            }
            watches.wall_in_one_state(current)
            assert(string.find(tooltipText, "panel.power.on_battery", 1, true))
            assert(string.find(tooltipText, "widget.paused", 1, true))
            current.animationInhibitionReason = "power-unavailable"
            watches.wall_in_one_state(current)
            assert(string.find(tooltipText, "panel.power.unavailable", 1, true))
        """
        with tempfile.TemporaryDirectory(prefix="wall-in-one-render-") as temporary:
            for entry, checks in (("panel.luau", panel_checks), ("widget.luau", widget_checks)):
                harness = Path(temporary) / entry
                harness.write_text(textwrap.dedent(prefix) + read(entry) + textwrap.dedent(checks))
                result = subprocess.run([str(runtime), str(harness)], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
