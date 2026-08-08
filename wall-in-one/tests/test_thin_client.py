"""Small offline contract test for the Wall-in-One 1.0 thin client."""

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
        self.assertEqual(manifest["version"], "1.0.0")
        self.assertEqual(manifest["plugin_api"], 17)
        self.assertEqual(manifest["dependencies"], ["wall-in-one"])

        expected = {
            "service": [("control", "service.luau")],
            "widget": [("wall-in-one", "widget.luau")],
            "panel": [("controls", "panel.luau")],
            "shortcut": [("wallpaper", "shortcut.luau")],
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
        # These keys are selected dynamically or passed through the panel's
        # shared toggle helper, so a literal tr() scan cannot see them.
        referenced.update(
            {
                "panel.cycle",
                "panel.dynamics",
                "panel.shuffle",
                "widget.off",
                "widget.on",
            }
        )
        missing = referenced - translations.keys()
        self.assertFalse(missing, f"missing translations: {missing}")

        actions = manifest["widget"][0]["actions"]
        for action in actions.values():
            if action.startswith("plugin "):
                self.assertRegex(
                    action,
                    r"^plugin goober/wall-in-one:control all "
                    r"(?:next|prev|random|dynamics)$",
                )
            elif action.startswith("panel-toggle "):
                self.assertEqual(action, "panel-toggle goober/wall-in-one:controls")
            else:
                self.fail(f"widget action bypasses a declared entry: {action}")

    def test_service_launch_and_retry_contract_is_explicit(self) -> None:
        source = read("service.luau")
        self.assertEqual(source.count("noctalia.runAsync("), 2)

        begin = source[
            source.index("local function beginLaunch") : source.index(
                "local function finish"
            )
        ]
        launch_lines = [
            line.strip() for line in begin.splitlines() if "noctalia.runAsync(" in line
        ]
        self.assertEqual(
            launch_lines,
            ['if not noctalia.runAsync(shellQuote(command) .. " --service") then'],
        )
        self.assertNotRegex(launch_lines[0], r"\bctl\b|function\s*\(|[,;&|]")

        invoke = source[
            source.index("invoke = function(job)") : source.index("pump = function()")
        ]
        for fragment in (
            'local parts = { shellQuote(command), "ctl", job.verb }',
            "table.insert(parts, shellQuote(job.argument))",
            'noctalia.runAsync(table.concat(parts, " "), function(result)',
            'if launching and job.verb == "status" then STARTUP_CALL_TIMEOUT_MS else CALL_TIMEOUT_MS',
        ):
            self.assertIn(fragment, invoke)

        constants = {
            name: int(value)
            for name, value in re.findall(
                r"local (CALL_TIMEOUT_MS|STARTUP_CALL_TIMEOUT_MS|STARTUP_POLL_MS|"
                r"STARTUP_TIMEOUT_SECONDS|QUEUE_LIMIT) = (\d+)",
                source,
            )
        }
        self.assertEqual(
            constants,
            {
                "CALL_TIMEOUT_MS": 8000,
                "STARTUP_CALL_TIMEOUT_MS": 1500,
                "STARTUP_POLL_MS": 250,
                "STARTUP_TIMEOUT_SECONDS": 10,
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
            local configuredBinary = "/tmp/wall in ' one"
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
                fileExists = function(path) return path == configuredBinary end,
                commandExists = function(_name) return false end,
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
            local quotedBinary = "'/tmp/wall in '\"'\"' one'"
            local function complete(index, result)
                assert(type(calls[index].callback) == "function", "call has no completion callback")
                calls[index].callback(result)
            end

            assert(#calls == 1, "initial status poll was not serialized")
            assert(calls[1].command == quotedBinary .. " ctl status", calls[1].command)
            assert(calls[1].timeout == 8000, "resting ctl timeout changed")
            complete(1, { timedOut = false, exitCode = 3, stdout = "", stderr = "" })

            onIpc("next", nil)
            assert(#calls == 2 and calls[2].command == quotedBinary .. " ctl next")
            assert(calls[2].timeout == 8000 and type(calls[2].callback) == "function")
            complete(2, { timedOut = false, exitCode = 3, stdout = "", stderr = "" })

            assert(#calls == 4, "stopped gesture did not launch and begin readiness polling")
            assert(calls[3].command == quotedBinary, calls[3].command)
            assert(calls[3].callback == nil and calls[3].timeout == nil, "app launch is not detached")
            assert(calls[4].command == quotedBinary .. " ctl status")
            assert(calls[4].timeout == 1500 and type(calls[4].callback) == "function")
            assert(startupDeadline == 110 and intervals[#intervals] == 250)

            now = 109
            complete(4, { timedOut = false, exitCode = 3, stdout = "", stderr = "" })
            assert(states[STATE_KEY].launching == true, "startup stopped before its deadline")
            update()
            assert(#calls == 5 and calls[5].timeout == 1500)
            now = 110
            complete(5, { timedOut = false, exitCode = 3, stdout = "", stderr = "" })
            assert(states[STATE_KEY].launching == false, "startup exceeded its deadline")
            assert(states[STATE_KEY].error == "state.launch_failed")
            assert(intervals[#intervals] == 15000, "startup poll rate leaked into resting state")

            onIpc("cycle-interval", { argument = "60" })
            assert(calls[6].command == quotedBinary .. " ctl cycle-interval '60'", calls[6].command)
            assert(calls[6].timeout == 8000 and type(calls[6].callback) == "function")
            for _index = 1, 20 do onIpc("random", nil) end
            assert(#queue == QUEUE_LIMIT and QUEUE_LIMIT == 8, "command queue is not bounded")
            complete(6, { timedOut = true, exitCode = 0, stdout = "", stderr = "" })
            assert(states[STATE_KEY].error == "state.timed_out", "ctl timeout was not surfaced")

            -- A fresh stopped gesture gets exactly one detached launch, one
            -- readiness probe, and one replay after the app reports ready.
            table.clear(queue)
            busy = false
            calls = {}
            now = 200
            onIpc("next", nil)
            assert(#calls == 1 and calls[1].command == quotedBinary .. " ctl next")
            complete(1, { timedOut = false, exitCode = 3, stdout = "", stderr = "" })
            assert(#calls == 3, "gesture did not create one launch and one readiness probe")
            assert(calls[2].command == quotedBinary and calls[2].callback == nil)
            assert(calls[3].command == quotedBinary .. " ctl status" and calls[3].timeout == 1500)
            complete(3, {
                timedOut = false,
                exitCode = 0,
                stdout = "set fixture.jpg; 1 of 1 playable; shuffle=off cycle=off cycle-interval=900 dynamics=on",
                stderr = "",
            })
            assert(#calls == 4 and calls[4].command == quotedBinary .. " ctl next")
            assert(calls[4].timeout == 8000, "replayed control kept the startup timeout")
            complete(4, { timedOut = false, exitCode = 0, stdout = "next", stderr = "" })
            assert(#calls == 5 and calls[5].command == quotedBinary .. " ctl status")
            complete(5, {
                timedOut = false,
                exitCode = 0,
                stdout = "set fixture.jpg; 1 of 1 playable; shuffle=off cycle=off cycle-interval=900 dynamics=on",
                stderr = "",
            })
            assert(states[STATE_KEY].running == true and states[STATE_KEY].launching == false)
            assert(states[STATE_KEY].showing == "set fixture.jpg")
            assert(states[STATE_KEY].playable == 1 and states[STATE_KEY].library == 1)
            assert(intervals[#intervals] == 15000, "successful startup did not restore resting polling")
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
