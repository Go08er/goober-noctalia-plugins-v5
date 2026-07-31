#!/usr/bin/env python3
"""Validate this custom Noctalia v5 plugin source without modifying it."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
PLUGIN_ID = re.compile(r"^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$")
TRANSLATION_KEY_SEGMENT = re.compile(r"^[a-z0-9-][a-z0-9_-]*$")
OLDEST_SUPPORTED_PLUGIN_API = 3
CURRENT_RELEASED_PLUGIN_API = 20
WIDGET_ACTIONS_PLUGIN_API = 14
OPEN_SETTINGS_PLUGIN_API = 15
DESCRIPTION_MAX_CHARS = 120
THUMBNAIL_MAX_BYTES = 512 * 1024
THUMBNAIL_SIZE = (960, 540)
WEBP_HEADER_BYTES = 32
ENTRY_TYPES = (
    "widget",
    "panel",
    "shortcut",
    "desktop_widget",
    "launcher_provider",
    "service",
)
SETTING_OWNER_TYPES = {"widget", "panel", "desktop_widget", "launcher_provider"}
SETTING_TYPES = {
    "string",
    "string_list",
    "string_map",
    "bool",
    "int",
    "double",
    "select",
    "file",
    "folder",
    "glyph",
    "color",
}
CATALOG_FIELDS = (
    "id",
    "name",
    "version",
    "author",
    "license",
    "icon",
    "description",
    "deprecated",
    "plugin_api",
    "tags",
    "dependencies",
)
REQUIRED_MANIFEST_FIELDS = set(CATALOG_FIELDS) - {"deprecated"}
ALLOWED_TAGS = {
    "ai",
    "animation",
    "arch",
    "audio",
    "bar",
    "clock",
    "countdown",
    "debian",
    "demo",
    "desktop",
    "development",
    "emoticon",
    "fedora",
    "fun",
    "gaming",
    "gentoo",
    "hardware",
    "hyprland",
    "indicator",
    "labwc",
    "language",
    "launcher",
    "mangowc",
    "media",
    "music",
    "network",
    "niri",
    "nixos",
    "opensuse",
    "panel",
    "privacy",
    "productivity",
    "recording",
    "service",
    "shortcut",
    "sway",
    "system",
    "theming",
    "time",
    "utility",
    "video",
    "void",
    "wallpaper",
}
TRANSLATION_CALL = re.compile(r'noctalia\.(?:tr|trp)\(\s*["\']([^"\']+)["\']')
CONFIG_CALL = re.compile(
    r'(?:noctalia\.getConfig|\bcfg|\bwidgetCfg)\(\s*["\']([^"\']+)["\']'
)
OBSOLETE_CONFIG_ACCESSOR = re.compile(r"\b(?:barWidget|desktopWidget|panel|launcher)\s*\.\s*getConfig\b")
OPEN_SETTINGS_CALL = re.compile(r"\bnoctalia\s*\.\s*openSettings\s*\(")
WIDGET_GESTURES = {
    "left",
    "right",
    "middle",
    "back",
    "forward",
    "scroll_up",
    "scroll_down",
    "scroll_left",
    "scroll_right",
}
V4_NAMES = {"manifest.json", "registry.json", "qmldir"}
V4_TOKENS = ("Quickshell", "QtQuick", "QtQml", "noctalia-qs")


class ValidationError(Exception):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, ValidationError) as error:
        raise ValidationError(f"{path.relative_to(ROOT)}: invalid JSON: {error}") from error


def load_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ValidationError(f"{path.relative_to(ROOT)}: invalid TOML: {error}") from error


def flatten_strings(value: Any, prefix: str = "") -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValidationError("translation root must be an object")
    flattened: dict[str, str] = {}
    for key, child in value.items():
        if not isinstance(key, str) or not key:
            raise ValidationError("translation keys must be non-empty strings")
        dotted = f"{prefix}.{key}" if prefix else key
        if TRANSLATION_KEY_SEGMENT.fullmatch(key) is None:
            raise ValidationError(
                f"translation key segment '{dotted}' must be lowercase, dot-free, and use only "
                "a-z, 0-9, dashes, and non-leading underscores"
            )
        if isinstance(child, dict):
            flattened.update(flatten_strings(child, dotted))
        elif isinstance(child, str):
            flattened[dotted] = child
        else:
            raise ValidationError(f"translation value for '{dotted}' must be a string")
    return flattened


def webp_dimensions(header: bytes) -> tuple[int, int] | None:
    """Read dimensions from the VP8X, VP8, or VP8L WebP header variants."""
    if len(header) < 16 or header[:4] != b"RIFF" or header[8:12] != b"WEBP":
        return None
    fourcc = header[12:16]
    payload = header[20:]
    if fourcc == b"VP8X":
        if len(payload) < 10:
            return None
        return (
            int.from_bytes(payload[4:7], "little") + 1,
            int.from_bytes(payload[7:10], "little") + 1,
        )
    if fourcc == b"VP8 ":
        if len(payload) < 10 or payload[3:6] != b"\x9d\x01\x2a":
            return None
        return (
            int.from_bytes(payload[6:8], "little") & 0x3FFF,
            int.from_bytes(payload[8:10], "little") & 0x3FFF,
        )
    if fourcc == b"VP8L":
        if len(payload) < 5 or payload[0] != 0x2F:
            return None
        bits = int.from_bytes(payload[1:5], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return None


def placeholders(text: str) -> set[str]:
    return set(re.findall(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", text))


def normalized_catalog_value(row: dict[str, Any], field: str) -> Any:
    if field == "license":
        return row.get(field, "MIT")
    if field == "deprecated":
        return row.get(field, False)
    if field in {"tags", "dependencies"}:
        return row.get(field, [])
    return row.get(field)


class Validator:
    def __init__(self, require_shellcheck: bool) -> None:
        self.require_shellcheck = require_shellcheck
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, path: Path, message: str) -> None:
        self.errors.append(f"{path.relative_to(ROOT)}: {message}")

    def require(self, condition: bool, path: Path, message: str) -> None:
        if not condition:
            self.error(path, message)

    def validate_source_json(self) -> None:
        for path in sorted(ROOT.rglob("*.json")):
            try:
                load_json(path)
            except ValidationError as error:
                self.errors.append(str(error))
        luaurc = ROOT / ".luaurc"
        if luaurc.exists():
            try:
                load_json(luaurc)
            except ValidationError as error:
                self.errors.append(str(error))

    def validate_source_toml(self) -> None:
        for path in sorted(ROOT.rglob("*.toml")):
            try:
                load_toml(path)
            except ValidationError as error:
                self.errors.append(str(error))

    def validate_no_v4_artifacts(self) -> None:
        for path in sorted(ROOT.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix.lower() in {".qml", ".qmlc", ".qmltypes"} or path.name in V4_NAMES:
                self.error(path, "v4/Quickshell artifact is not allowed in the v5 source")
            if path.suffix == ".luau" or "scripts" in path.parts:
                try:
                    source = path.read_text(errors="replace")
                except OSError as error:
                    self.error(path, f"cannot read runtime source: {error}")
                    continue
                for token in V4_TOKENS:
                    if token in source:
                        self.error(path, f"runtime source contains forbidden v4 token '{token}'")

    def load_translations(self, plugin_dir: Path) -> dict[str, str]:
        english_path = plugin_dir / "translations" / "en.json"
        if not english_path.is_file():
            self.error(plugin_dir, "missing translations/en.json")
            return {}
        try:
            english = flatten_strings(load_json(english_path))
        except ValidationError as error:
            self.errors.append(str(error))
            return {}

        translations_dir = english_path.parent
        for locale_path in sorted(translations_dir.glob("*.json")):
            if locale_path == english_path:
                continue
            try:
                locale = flatten_strings(load_json(locale_path))
            except ValidationError as error:
                self.errors.append(str(error))
                continue
            for key, text in locale.items():
                if key not in english:
                    self.error(locale_path, f"translation key '{key}' is absent from en.json")
                elif placeholders(text) != placeholders(english[key]):
                    self.error(locale_path, f"placeholder mismatch for translation key '{key}'")
        return english

    def require_translation(self, path: Path, translations: dict[str, str], key: Any, context: str) -> None:
        if not isinstance(key, str) or not key:
            self.error(path, f"{context} must be a non-empty translation key")
        elif key not in translations:
            self.error(path, f"{context} references missing translation '{key}'")

    def validate_setting(
        self,
        path: Path,
        setting: Any,
        translations: dict[str, str],
        context: str,
    ) -> str | None:
        if not isinstance(setting, dict):
            self.error(path, f"{context} must be a table")
            return None

        key = setting.get("key")
        if not isinstance(key, str) or not key:
            self.error(path, f"{context}.key must be a non-empty string")
            key = None

        setting_type = setting.get("type")
        if setting_type not in SETTING_TYPES:
            self.error(path, f"{context}.type is unsupported: {setting_type!r}")

        if "label" in setting:
            self.error(path, f"{context}.label is no longer supported; use label_key")
        self.require_translation(path, translations, setting.get("label_key"), f"{context}.label_key")

        if "description" in setting:
            self.error(path, f"{context}.description is no longer supported; use description_key")
        if "description_key" in setting:
            self.require_translation(
                path,
                translations,
                setting["description_key"],
                f"{context}.description_key",
            )

        default = setting.get("default")
        if setting_type in {"string", "file", "folder", "glyph", "color", "select"}:
            self.require(isinstance(default, str), path, f"{context}.default must be a string")
        elif setting_type == "string_list":
            self.require(
                isinstance(default, list) and all(isinstance(item, str) for item in default),
                path,
                f"{context}.default must be an array of strings",
            )
        elif setting_type == "string_map":
            self.require(
                isinstance(default, dict)
                and all(isinstance(item, str) for item in default.values()),
                path,
                f"{context}.default must be a table of string values",
            )
        elif setting_type == "bool":
            self.require(type(default) is bool, path, f"{context}.default must be a boolean")
        elif setting_type == "int":
            self.require(type(default) is int, path, f"{context}.default must be an integer")
        elif setting_type == "double":
            self.require(
                type(default) in {int, float},
                path,
                f"{context}.default must be numeric",
            )

        options = setting.get("options")
        if setting_type == "select":
            if not isinstance(options, list) or not options:
                self.error(path, f"{context}.options must be a non-empty array")
            else:
                option_values: list[str] = []
                for index, option in enumerate(options):
                    option_context = f"{context}.options[{index}]"
                    if not isinstance(option, dict):
                        self.error(path, f"{option_context} must be a table")
                        continue
                    value = option.get("value")
                    if not isinstance(value, str) or not value:
                        self.error(path, f"{option_context}.value must be a non-empty string")
                    else:
                        option_values.append(value)
                    if "label" in option:
                        self.error(path, f"{option_context}.label is no longer supported; use label_key")
                    self.require_translation(
                        path,
                        translations,
                        option.get("label_key"),
                        f"{option_context}.label_key",
                    )
                if len(option_values) != len(set(option_values)):
                    self.error(path, f"{context}.options contains duplicate values")
                if default not in option_values:
                    self.error(path, f"{context}.default must match an option value")
        elif options is not None:
            self.error(path, f"{context}.options is valid only for select settings")

        if setting_type in {"int", "double"}:
            minimum = setting.get("min")
            maximum = setting.get("max")
            step = setting.get("step")
            allowed_numeric_types = {int} if setting_type == "int" else {int, float}

            def numeric(value: Any) -> bool:
                return type(value) in allowed_numeric_types

            if minimum is not None and not numeric(minimum):
                self.error(path, f"{context}.min has the wrong numeric type")
            if maximum is not None and not numeric(maximum):
                self.error(path, f"{context}.max has the wrong numeric type")
            if step is not None and (not numeric(step) or step <= 0):
                self.error(path, f"{context}.step must be positive")
            if numeric(minimum) and numeric(maximum) and minimum > maximum:
                self.error(path, f"{context}.min must not exceed max")
            if numeric(default) and numeric(minimum) and default < minimum:
                self.error(path, f"{context}.default is below min")
            if numeric(default) and numeric(maximum) and default > maximum:
                self.error(path, f"{context}.default is above max")

        visible_when = setting.get("visible_when")
        if visible_when is not None:
            if not isinstance(visible_when, dict):
                self.error(path, f"{context}.visible_when must be a table")
            else:
                target = visible_when.get("key")
                values = visible_when.get("values")
                if not isinstance(target, str) or not target:
                    self.error(path, f"{context}.visible_when.key must be a non-empty string")
                if not isinstance(values, list) or not values or not all(
                    isinstance(value, str) and value for value in values
                ):
                    self.error(path, f"{context}.visible_when.values must be non-empty strings")

        if "advanced" in setting and type(setting["advanced"]) is not bool:
            self.error(path, f"{context}.advanced must be a boolean")
        return key

    def validate_settings(
        self,
        path: Path,
        settings: Any,
        translations: dict[str, str],
        context: str,
    ) -> set[str]:
        if not isinstance(settings, list):
            self.error(path, f"{context} must be an array of tables")
            return set()
        keys: list[str] = []
        for index, setting in enumerate(settings):
            key = self.validate_setting(path, setting, translations, f"{context}[{index}]")
            if key is not None:
                keys.append(key)
        if len(keys) != len(set(keys)):
            self.error(path, f"{context} contains duplicate setting keys")
        key_set = set(keys)
        for index, setting in enumerate(settings):
            if not isinstance(setting, dict) or not isinstance(setting.get("visible_when"), dict):
                continue
            target = setting["visible_when"].get("key")
            if isinstance(target, str) and target not in key_set:
                self.error(path, f"{context}[{index}].visible_when references undeclared key '{target}'")
        return key_set

    def validate_entry_path(self, manifest_path: Path, plugin_dir: Path, entry_path: Any, context: str) -> Path | None:
        if not isinstance(entry_path, str) or not entry_path.endswith(".luau"):
            self.error(manifest_path, f"{context}.entry must name a relative .luau file")
            return None
        relative = Path(entry_path)
        if relative.is_absolute() or ".." in relative.parts:
            self.error(manifest_path, f"{context}.entry must stay inside the plugin directory")
            return None
        resolved = (plugin_dir / relative).resolve()
        try:
            resolved.relative_to(plugin_dir.resolve())
        except ValueError:
            self.error(manifest_path, f"{context}.entry resolves outside the plugin directory")
            return None
        if not resolved.is_file():
            self.error(manifest_path, f"{context}.entry file does not exist: {entry_path}")
            return None
        first_line = resolved.read_text(errors="replace").splitlines()[:1]
        if first_line != ["--!nonstrict"]:
            self.error(resolved, "Luau entry must start with --!nonstrict")
        return resolved

    def validate_runtime_references(
        self,
        entry_path: Path,
        translations: dict[str, str],
        allowed_settings: set[str],
        plugin_api: Any,
    ) -> None:
        source = entry_path.read_text(errors="replace")
        for accessor in OBSOLETE_CONFIG_ACCESSOR.findall(source):
            self.error(entry_path, f"removed config accessor '{accessor}'; use noctalia.getConfig")
        for key in TRANSLATION_CALL.findall(source):
            if key not in translations:
                self.error(entry_path, f"runtime references missing translation '{key}'")
        for key in CONFIG_CALL.findall(source):
            if key not in allowed_settings:
                self.error(entry_path, f"runtime reads undeclared setting '{key}'")
        if OPEN_SETTINGS_CALL.search(source) and (
            type(plugin_api) is not int or plugin_api < OPEN_SETTINGS_PLUGIN_API
        ):
            self.error(
                entry_path,
                f"noctalia.openSettings requires plugin_api >= {OPEN_SETTINGS_PLUGIN_API}",
            )

    def validate_plugin(self, plugin_dir: Path) -> tuple[dict[str, Any], Path]:
        manifest_path = plugin_dir / "plugin.toml"
        try:
            manifest = load_toml(manifest_path)
        except ValidationError as error:
            self.errors.append(str(error))
            return {}, manifest_path

        translations = self.load_translations(plugin_dir)
        for field in REQUIRED_MANIFEST_FIELDS:
            self.require(field in manifest, manifest_path, f"missing publishing metadata '{field}'")

        plugin_id = manifest.get("id")
        if not isinstance(plugin_id, str) or PLUGIN_ID.fullmatch(plugin_id) is None:
            self.error(manifest_path, "id must be exactly author/plugin using supported characters")
        else:
            author, slug = plugin_id.split("/")
            self.require(manifest.get("author") == author, manifest_path, "author must match the id prefix")
            self.require(plugin_dir.name == slug, manifest_path, "directory must match the id suffix")

        for field in ("name", "version", "author", "license", "icon", "description"):
            self.require(
                isinstance(manifest.get(field), str) and bool(manifest[field].strip()),
                manifest_path,
                f"{field} must be a non-empty string",
            )
        version = manifest.get("version")
        if isinstance(version, str):
            self.require(SEMVER.fullmatch(version) is not None, manifest_path, "version must use MAJOR.MINOR.PATCH")
        if "min_noctalia" in manifest:
            self.error(manifest_path, "min_noctalia was replaced by the mandatory plugin_api compatibility level")
        plugin_api = manifest.get("plugin_api")
        if type(plugin_api) is not int or plugin_api <= 0:
            self.error(manifest_path, "plugin_api must be a positive integer")
        else:
            self.require(
                OLDEST_SUPPORTED_PLUGIN_API <= plugin_api <= CURRENT_RELEASED_PLUGIN_API,
                manifest_path,
                f"plugin_api must be supported by the current released host "
                f"({OLDEST_SUPPORTED_PLUGIN_API}..{CURRENT_RELEASED_PLUGIN_API})",
            )
        for field in ("tags", "dependencies"):
            value = manifest.get(field)
            self.require(
                isinstance(value, list) and all(isinstance(item, str) and item for item in value),
                manifest_path,
                f"{field} must be an array of non-empty strings",
            )
        self.require(bool(manifest.get("tags")), manifest_path, "tags must not be empty")
        tags = manifest.get("tags")
        if isinstance(tags, list):
            for tag in tags:
                if isinstance(tag, str) and tag not in ALLOWED_TAGS:
                    self.error(manifest_path, f"unsupported catalog tag '{tag}'")
        description = manifest.get("description")
        if isinstance(description, str):
            self.require(
                len(description) <= DESCRIPTION_MAX_CHARS,
                manifest_path,
                f"description must not exceed {DESCRIPTION_MAX_CHARS} characters",
            )
        if "deprecated" in manifest:
            self.require(type(manifest["deprecated"]) is bool, manifest_path, "deprecated must be a boolean")

        for required_asset in ("README.md", "LICENSE", "thumbnail.webp"):
            asset = plugin_dir / required_asset
            self.require(asset.is_file() and asset.stat().st_size > 0, manifest_path, f"missing non-empty {required_asset}")
        thumbnail = plugin_dir / "thumbnail.webp"
        if thumbnail.is_file():
            size = thumbnail.stat().st_size
            self.require(
                size <= THUMBNAIL_MAX_BYTES,
                thumbnail,
                f"thumbnail must not exceed {THUMBNAIL_MAX_BYTES} bytes",
            )
            with thumbnail.open("rb") as handle:
                header = handle.read(WEBP_HEADER_BYTES)
            self.require(
                len(header) >= 12 and header[:4] == b"RIFF" and header[8:12] == b"WEBP",
                thumbnail,
                "invalid WebP signature",
            )
            dimensions = webp_dimensions(header)
            self.require(
                dimensions == THUMBNAIL_SIZE,
                thumbnail,
                f"thumbnail must be {THUMBNAIL_SIZE[0]}x{THUMBNAIL_SIZE[1]}",
            )

        root_settings = self.validate_settings(
            manifest_path,
            manifest.get("setting", []),
            translations,
            "setting",
        )
        entry_count = 0
        seen_entry_ids: set[str] = set()
        runtime_entries: list[tuple[Path, set[str]]] = []
        for entry_type in ENTRY_TYPES:
            entries = manifest.get(entry_type, [])
            if not isinstance(entries, list):
                self.error(manifest_path, f"{entry_type} must be an array of tables")
                continue
            for index, entry in enumerate(entries):
                entry_count += 1
                context = f"{entry_type}[{index}]"
                if not isinstance(entry, dict):
                    self.error(manifest_path, f"{context} must be a table")
                    continue
                entry_id = entry.get("id")
                if not isinstance(entry_id, str) or not entry_id:
                    self.error(manifest_path, f"{context}.id must be a non-empty string")
                elif entry_id in seen_entry_ids:
                    self.error(manifest_path, f"duplicate entry id '{entry_id}'")
                else:
                    seen_entry_ids.add(entry_id)
                entry_file = self.validate_entry_path(manifest_path, plugin_dir, entry.get("entry"), context)
                if entry_type == "widget" and "actions" in entry:
                    actions = entry["actions"]
                    if type(plugin_api) is not int or plugin_api < WIDGET_ACTIONS_PLUGIN_API:
                        self.error(
                            manifest_path,
                            f"{context}.actions requires plugin_api >= {WIDGET_ACTIONS_PLUGIN_API}",
                        )
                    if not isinstance(actions, dict):
                        self.error(manifest_path, f"{context}.actions must be a table")
                    else:
                        for gesture, action in actions.items():
                            if gesture not in WIDGET_GESTURES:
                                self.error(manifest_path, f"{context}.actions has unknown gesture '{gesture}'")
                            if not isinstance(action, str) or not action.strip():
                                self.error(
                                    manifest_path,
                                    f"{context}.actions.{gesture} must be a non-empty action string",
                                )
                entry_settings = set()
                if "setting" in entry:
                    if entry_type not in SETTING_OWNER_TYPES:
                        self.error(manifest_path, f"{context} cannot declare entry-level settings")
                    else:
                        entry_settings = self.validate_settings(
                            manifest_path,
                            entry["setting"],
                            translations,
                            f"{context}.setting",
                        )
                if entry_file is not None:
                    runtime_entries.append((entry_file, root_settings | entry_settings))
        self.require(entry_count > 0, manifest_path, "manifest must declare at least one entry")

        for entry_path, allowed_settings in runtime_entries:
            self.validate_runtime_references(entry_path, translations, allowed_settings, plugin_api)
        return manifest, manifest_path

    def validate_shell_helpers(self) -> None:
        shellcheck = shutil.which("shellcheck")
        if self.require_shellcheck and shellcheck is None:
            self.errors.append("shellcheck is required but was not found on PATH")
        elif shellcheck is None:
            self.warnings.append("shellcheck not found; skipped shell lint")

        for scripts_dir in sorted(ROOT.glob("*/scripts")):
            for path in sorted(scripts_dir.rglob("*")):
                if not path.is_file():
                    continue
                first_line = path.read_text(errors="replace").splitlines()[:1]
                if not first_line or not first_line[0].startswith("#!"):
                    continue
                self.require(os.access(path, os.X_OK), path, "script must be executable")
                shell = "bash" if "bash" in first_line[0] else "sh" if "sh" in first_line[0] else None
                if shell is None:
                    self.error(path, f"unsupported script interpreter: {first_line[0]}")
                    continue
                syntax = subprocess.run(
                    [shell, "-n", str(path)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if syntax.returncode != 0:
                    self.error(path, f"shell syntax failed: {syntax.stderr.strip()}")
                if shellcheck is not None:
                    lint = subprocess.run(
                        [shellcheck, "-x", str(path)],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    if lint.returncode != 0:
                        self.error(path, f"shellcheck failed:\n{lint.stdout.strip()}")

    def validate(self) -> int:
        self.validate_source_json()
        self.validate_source_toml()
        self.validate_no_v4_artifacts()

        catalog_path = ROOT / "catalog.toml"
        if not catalog_path.is_file():
            self.errors.append("catalog.toml: missing source catalog")
            catalog: dict[str, Any] = {}
        else:
            try:
                catalog = load_toml(catalog_path)
            except ValidationError as error:
                self.errors.append(str(error))
                catalog = {}

        plugin_dirs = sorted(path.parent for path in ROOT.glob("*/plugin.toml"))
        if not plugin_dirs:
            self.errors.append("no immediate */plugin.toml manifests found")

        manifests: dict[str, tuple[dict[str, Any], Path]] = {}
        for plugin_dir in plugin_dirs:
            manifest, manifest_path = self.validate_plugin(plugin_dir)
            plugin_id = manifest.get("id")
            if isinstance(plugin_id, str):
                if plugin_id in manifests:
                    self.error(manifest_path, f"duplicate plugin id '{plugin_id}'")
                manifests[plugin_id] = (manifest, manifest_path)

        rows = catalog.get("plugin", [])
        if not isinstance(rows, list):
            self.error(catalog_path, "[[plugin]] rows must be an array")
            rows = []
        catalog_rows: dict[str, tuple[dict[str, Any], int]] = {}
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                self.error(catalog_path, f"plugin[{index}] must be a table")
                continue
            plugin_id = row.get("id")
            if not isinstance(plugin_id, str) or not plugin_id:
                self.error(catalog_path, f"plugin[{index}].id must be a non-empty string")
                continue
            if plugin_id in catalog_rows:
                self.error(catalog_path, f"duplicate catalog id '{plugin_id}'")
            catalog_rows[plugin_id] = (row, index)

        for plugin_id, (manifest, manifest_path) in manifests.items():
            if plugin_id not in catalog_rows:
                self.error(manifest_path, "plugin is missing from catalog.toml")
                continue
            row, index = catalog_rows[plugin_id]
            for field in CATALOG_FIELDS:
                if normalized_catalog_value(row, field) != normalized_catalog_value(manifest, field):
                    self.error(catalog_path, f"plugin[{index}].{field} does not match {manifest_path.parent.name}/plugin.toml")
        for plugin_id, (_, index) in catalog_rows.items():
            if plugin_id not in manifests:
                self.error(catalog_path, f"plugin[{index}] has no matching immediate plugin directory")

        self.validate_shell_helpers()

        for warning in self.warnings:
            print(f"warning: {warning}", file=sys.stderr)
        for error in self.errors:
            print(f"error: {error}", file=sys.stderr)
        if self.errors:
            return 1
        print(f"Validated {len(manifests)} Noctalia v5 plugin(s).")
        return 0


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--require-shellcheck",
        action="store_true",
        help="fail instead of warning when shellcheck is unavailable",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    return Validator(require_shellcheck=args.require_shellcheck).validate()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
