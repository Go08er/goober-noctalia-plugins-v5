#!/usr/bin/env python3
"""Static contract checks for the conservative NocVox MVP."""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = tomllib.loads((ROOT / "plugin.toml").read_text(encoding="utf-8"))
TRANSLATIONS = json.loads((ROOT / "translations/en.json").read_text(encoding="utf-8"))
LUAU = {path.name: path.read_text(encoding="utf-8") for path in ROOT.glob("*.luau")}


def translation_value(key: str) -> object:
    value: object = TRANSLATIONS
    for segment in key.split("."):
        assert isinstance(value, dict) and segment in value, f"missing translation key: {key}"
        value = value[segment]
    return value


def check_translation_tree(value: object, location: str = "") -> None:
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        assert re.fullmatch(r"[a-z0-9_]+", key), f"invalid translation segment: {location}{key}"
        check_translation_tree(child, f"{location}{key}.")


assert MANIFEST["id"] == "goober/nocvox"
assert MANIFEST["name"] == "NocVox"
assert MANIFEST["plugin_api"] == 17
assert len(MANIFEST.get("service", [])) == 1
assert MANIFEST["service"][0] == {"id": "listener", "entry": "service.luau"}
assert len(MANIFEST.get("widget", [])) == 1
assert len(MANIFEST.get("panel", [])) == 1

widget = MANIFEST["widget"][0]
assert widget["id"] == "nocvox"
widget_settings = {setting["key"]: setting for setting in widget["setting"]}
assert widget["actions"]["middle"] == "none"
assert widget_settings["left_action"]["default"] == "toggle"
assert widget_settings["middle_action"]["default"] == "cancel"
assert widget_settings["right_action"]["default"] == "cancel"
for glyph_key in ("idle_glyph", "active_glyph", "stopped_glyph", "unknown_glyph"):
    assert widget_settings[glyph_key]["type"] == "glyph"

root_settings = {setting["key"]: setting for setting in MANIFEST.get("setting", [])}
assert root_settings["enable_one_shot_overrides"]["default"] is False

check_translation_tree(TRANSLATIONS)
for setting in [*MANIFEST.get("setting", []), *widget.get("setting", [])]:
    translation_value(setting["label_key"])
    if "description_key" in setting:
        translation_value(setting["description_key"])
    for option in setting.get("options", []):
        translation_value(option["label_key"])

stream_owners = {name: source.count("noctalia.runStream(") for name, source in LUAU.items()}
assert sum(stream_owners.values()) == 1, f"expected one status follower, got {stream_owners}"
assert stream_owners.get("service.luau") == 1
assert (
    'local FOLLOW_COMMAND = "voxtype status --follow --format json --extended --icon-theme text"'
    in LUAU["service.luau"]
)
assert 'local COMMAND_ACK_KEY = "voxtype_command_ack"' in LUAU["service.luau"]
assert "handleCommand(noctalia.state.get(COMMAND_KEY))" in LUAU["service.luau"]
assert 'dispatchCommand({\n        action = event,\n        producer = "ipc",' in LUAU["service.luau"]
assert "sequence = lastCommandSequence + 1" not in LUAU["service.luau"]
assert "previousDiagnostics.pending == true" in LUAU["service.luau"]
assert translation_value("errors.diagnostics_interrupted").startswith("Diagnostics were interrupted")
assert translation_value("overrides.text_actions") == "Text-action options"

combined = "\n".join(LUAU.values())
for forbidden in (
    "voxtype daemon",
    "voxtype configure",
    "voxtype setup",
    "voxtype check-update",
    "systemctl",
    "clipboardText(",
    "noctalia.readFile(",
    "noctalia.writeFile(",
    "noctalia.removeFile(",
    "noctalia.renameFile(",
):
    assert forbidden not in combined, f"forbidden companion behavior: {forbidden}"

assert "noctalia.copyToClipboard(" not in LUAU["service.luau"]
assert "noctalia.copyToClipboard(" not in LUAU["widget.luau"]
assert LUAU["panel.luau"].count("noctalia.copyToClipboard(") == 1
assert "Clipboard and paste are one-shot VoxType output destinations only" in json.dumps(TRANSLATIONS)
assert "absolute path is validated and shell-quoted" in json.dumps(TRANSLATIONS)

print("NocVox static contract checks passed")
