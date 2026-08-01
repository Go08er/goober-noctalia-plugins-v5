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
assert MANIFEST["version"] == "0.3.0"
assert MANIFEST["plugin_api"] == 17
assert len(MANIFEST.get("service", [])) == 1
assert MANIFEST["service"][0] == {"id": "listener", "entry": "service.luau"}
assert len(MANIFEST.get("widget", [])) == 1
assert len(MANIFEST.get("panel", [])) == 1

widget = MANIFEST["widget"][0]
assert widget["id"] == "nocvox"
widget_settings = {setting["key"]: setting for setting in widget["setting"]}
assert widget["actions"] == {
    "left": "plugin goober/nocvox:listener all toggle",
    "right": "panel-toggle goober/nocvox:details",
}
assert set(widget_settings) == {
    "tooltip_show_model",
    "tooltip_show_device",
    "tooltip_show_backend",
    "idle_color",
    "recording_color",
    "transcribing_color",
    "stopped_color",
    "unknown_color",
    "idle_display",
    "active_label",
    "width_mode",
    "idle_glyph",
    "active_glyph",
    "stopped_glyph",
    "unknown_glyph",
}
for glyph_key in ("idle_glyph", "active_glyph", "stopped_glyph", "unknown_glyph"):
    assert widget_settings[glyph_key]["type"] == "glyph"
for color_key in ("idle_color", "recording_color", "transcribing_color", "stopped_color", "unknown_color"):
    assert widget_settings[color_key]["type"] == "color"

root_settings = {setting["key"]: setting for setting in MANIFEST.get("setting", [])}
removed_root_settings = {"notify_transitions", "notify_failures", "enable_one_shot_overrides"}
removed_widget_settings = {"left_action", "middle_action", "right_action", "show_override_name"}
assert root_settings == {}
assert removed_root_settings.isdisjoint(root_settings)
assert removed_widget_settings.isdisjoint(widget_settings)

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
assert "gestures" not in TRANSLATIONS["settings"]
for removed_tree in ("notifications", "overrides"):
    assert removed_tree not in TRANSLATIONS

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
    "noctalia.notify(",
    "noctalia.notifyError(",
    "enable_one_shot_overrides",
    "show_override_name",
    "override_active",
    ".overrides",
    "--type",
    "--clipboard",
    "--paste",
    "--file",
    "--model",
    "--profile",
    "--auto-submit",
    "--shift-enter-newlines",
    "--smart-auto-submit",
    "left_action",
    "middle_action",
    "right_action",
):
    assert forbidden not in combined, f"forbidden companion behavior: {forbidden}"

service = LUAU["service.luau"]
assert service.count('runControl("voxtype record start", "start")') == 1
assert service.count('runControl("voxtype record stop", "stop")') == 1
assert service.count('runControl("voxtype record cancel", "cancel")') == 1
assert "noctalia.copyToClipboard(" not in LUAU["service.luau"]
assert "noctalia.copyToClipboard(" not in LUAU["widget.luau"]
assert LUAU["panel.luau"].count("noctalia.copyToClipboard(") == 1
assert "noctalia.getConfig(" not in LUAU["panel.luau"]
assert "noctalia.openSettings(" not in LUAU["panel.luau"]
assert "function onClick(" not in LUAU["widget.luau"]
assert "function onMiddleClick(" not in LUAU["widget.luau"]
assert "function onRightClick(" not in LUAU["widget.luau"]
assert "desktop notification" not in json.dumps(TRANSLATIONS).lower()

print("NocVox static contract checks passed")
