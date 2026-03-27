#!/usr/bin/env python3

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import tempfile
from pathlib import Path

PLUGIN_NAME = "easy-loop"
DEFAULT_MARKETPLACE_NAME = "local"
DEFAULT_MARKETPLACE_DISPLAY_NAME = "Local Plugins"
PLUGIN_STATUS_MESSAGE = "Easy Loop stop hook"
PLUGIN_CATEGORY = "Development"
DEFAULT_PLUGIN_VERSION = "local"


def error(message: str) -> None:
    raise SystemExit(message)


def load_json_file(path: Path, default: dict) -> dict:
    if not path.exists():
        return copy.deepcopy(default)
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return copy.deepcopy(default)
    data = json.loads(text)
    if not isinstance(data, dict):
        error(f"Expected a JSON object in {path}")
    return data


def write_json_file(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def same_path(left: Path, right: Path) -> bool:
    try:
        return left.resolve() == right.resolve()
    except FileNotFoundError:
        return left.absolute() == right.absolute()


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def copy_tree_atomic(source: Path, destination: Path) -> None:
    if same_path(source, destination):
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="easy-loop-copy-", dir=destination.parent) as tempdir:
        staging = Path(tempdir) / destination.name
        shutil.copytree(
            source,
            staging,
            ignore=shutil.ignore_patterns(".git", ".codex", "__pycache__", ".pytest_cache", ".ruff_cache"),
            symlinks=True,
        )
        if destination.exists():
            remove_path(destination)
        os.replace(staging, destination)


def home_root_from_agents_home(agents_home: Path) -> Path:
    return agents_home.parent


def relative_marketplace_source_path(plugin_root: Path, agents_home: Path) -> str:
    home_root = home_root_from_agents_home(agents_home)
    try:
        relative = plugin_root.resolve().relative_to(home_root.resolve())
    except ValueError:
        error(
            f"Plugin root {plugin_root} must live under the home root {home_root} for a home-local marketplace."
        )
    return "./" + relative.as_posix()


def merge_marketplace(marketplace_path: Path, plugin_root: Path, agents_home: Path) -> str:
    data = load_json_file(
        marketplace_path,
        {
            "name": DEFAULT_MARKETPLACE_NAME,
            "interface": {"displayName": DEFAULT_MARKETPLACE_DISPLAY_NAME},
            "plugins": [],
        },
    )

    name = data.get("name")
    if not isinstance(name, str) or not name.strip():
        name = DEFAULT_MARKETPLACE_NAME
        data["name"] = name

    interface = data.get("interface")
    if not isinstance(interface, dict):
        interface = {}
        data["interface"] = interface
    interface.setdefault("displayName", DEFAULT_MARKETPLACE_DISPLAY_NAME)

    plugins = data.get("plugins")
    if not isinstance(plugins, list):
        plugins = []
        data["plugins"] = plugins

    entry = {
        "name": PLUGIN_NAME,
        "source": {
            "source": "local",
            "path": relative_marketplace_source_path(plugin_root, agents_home),
        },
        "policy": {
            "installation": "INSTALLED_BY_DEFAULT",
            "authentication": "ON_INSTALL",
        },
        "category": PLUGIN_CATEGORY,
    }

    replaced = False
    for index, plugin in enumerate(plugins):
        if isinstance(plugin, dict) and plugin.get("name") == PLUGIN_NAME:
            plugins[index] = entry
            replaced = True
            break
    if not replaced:
        plugins.append(entry)

    write_json_file(marketplace_path, data)
    return name


def cache_plugin(source_root: Path, codex_home: Path, marketplace_name: str) -> Path:
    cache_root = codex_home / "plugins" / "cache" / marketplace_name / PLUGIN_NAME / DEFAULT_PLUGIN_VERSION
    copy_tree_atomic(source_root, cache_root)
    return cache_root


def replace_or_insert_dotted_assignment(text: str, dotted_key: str, value_literal: str) -> tuple[str, bool]:
    pattern = re.compile(rf"(?m)^(?P<indent>\s*){re.escape(dotted_key)}\s*=.*$")
    replacement = rf"\g<indent>{dotted_key} = {value_literal}"
    new_text, count = pattern.subn(replacement, text)
    return new_text, count > 0


def remove_matching_dotted_assignments(text: str, dotted_pattern: str) -> str:
    lines = [line for line in text.splitlines() if not re.match(dotted_pattern, line)]
    return "\n".join(lines).rstrip() + ("\n" if lines else "")


def upsert_table_key(text: str, table_header: str, key: str, value_literal: str) -> str:
    lines = text.splitlines()
    header = f"[{table_header}]"

    start = None
    end = len(lines)
    for index, line in enumerate(lines):
        if line.strip() == header:
            start = index
            break

    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([header, f"{key} = {value_literal}"])
        return "\n".join(lines).rstrip() + "\n"

    for index in range(start + 1, len(lines)):
        if lines[index].strip().startswith("[") and lines[index].strip().endswith("]"):
            end = index
            break

    assignment_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index in range(start + 1, end):
        if assignment_pattern.match(lines[index]):
            lines[index] = f"{key} = {value_literal}"
            return "\n".join(lines).rstrip() + "\n"

    lines.insert(end, f"{key} = {value_literal}")
    return "\n".join(lines).rstrip() + "\n"


def remove_table(text: str, table_header_pattern: str) -> str:
    lines = text.splitlines()
    kept: list[str] = []
    index = 0
    header_re = re.compile(table_header_pattern)
    while index < len(lines):
        line = lines[index]
        if header_re.match(line.strip()):
            index += 1
            while index < len(lines):
                stripped = lines[index].strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    break
                index += 1
            continue
        kept.append(line)
        index += 1

    while kept and not kept[-1].strip():
        kept.pop()
    return "\n".join(kept).rstrip() + ("\n" if kept else "")


def update_config_for_install(config_path: Path, plugin_key: str) -> None:
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    if text and not text.endswith("\n"):
        text += "\n"

    for dotted_key in ("features.plugins", "features.codex_hooks"):
        text, replaced = replace_or_insert_dotted_assignment(text, dotted_key, "true")
        if not replaced:
            table_name, key_name = dotted_key.split(".", 1)
            text = upsert_table_key(text, table_name, key_name, "true")

    dotted_plugin_key = f'plugins."{plugin_key}".enabled'
    text, replaced = replace_or_insert_dotted_assignment(text, dotted_plugin_key, "true")
    if not replaced:
        text = upsert_table_key(text, f'plugins."{plugin_key}"', "enabled", "true")

    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(text, encoding="utf-8")


def update_config_for_uninstall(config_path: Path) -> None:
    if not config_path.exists():
        return

    text = config_path.read_text(encoding="utf-8")
    text = remove_matching_dotted_assignments(
        text,
        r'^\s*plugins\."easy-loop@[^"]+"\.(enabled)\s*=.*$',
    )
    text = remove_table(text, r'^\[plugins\."easy-loop@[^"]+"\]$')
    config_path.write_text(text, encoding="utf-8")


def merge_hooks(hooks_path: Path, stop_hook_command: str) -> None:
    data = load_json_file(hooks_path, {"hooks": {}})
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        error(f"Expected 'hooks' to be an object in {hooks_path}")

    stop_groups = hooks.get("Stop")
    if not isinstance(stop_groups, list):
        stop_groups = []
        hooks["Stop"] = stop_groups

    found = False
    for group in stop_groups:
        if not isinstance(group, dict):
            continue
        group_hooks = group.get("hooks")
        if not isinstance(group_hooks, list):
            continue
        for entry in group_hooks:
            if not isinstance(entry, dict):
                continue
            if entry.get("type") != "command":
                continue
            if entry.get("command") == stop_hook_command or entry.get("statusMessage") == PLUGIN_STATUS_MESSAGE:
                entry["command"] = stop_hook_command
                entry["statusMessage"] = PLUGIN_STATUS_MESSAGE
                found = True

    if not found:
        stop_groups.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": stop_hook_command,
                        "statusMessage": PLUGIN_STATUS_MESSAGE,
                    }
                ]
            }
        )

    write_json_file(hooks_path, data)


def remove_hooks(hooks_path: Path, stop_hook_command: str) -> None:
    if not hooks_path.exists():
        return

    data = load_json_file(hooks_path, {"hooks": {}})
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return

    stop_groups = hooks.get("Stop")
    if not isinstance(stop_groups, list):
        return

    cleaned_groups = []
    for group in stop_groups:
        if not isinstance(group, dict):
            continue
        group_hooks = group.get("hooks")
        if not isinstance(group_hooks, list):
            continue
        cleaned_hooks = []
        for entry in group_hooks:
            if not isinstance(entry, dict):
                continue
            if entry.get("type") != "command":
                cleaned_hooks.append(entry)
                continue
            if entry.get("command") == stop_hook_command or entry.get("statusMessage") == PLUGIN_STATUS_MESSAGE:
                continue
            cleaned_hooks.append(entry)
        if cleaned_hooks:
            group["hooks"] = cleaned_hooks
            cleaned_groups.append(group)

    if cleaned_groups:
        hooks["Stop"] = cleaned_groups
    else:
        hooks.pop("Stop", None)

    write_json_file(hooks_path, data)


def remove_plugin_from_marketplace(marketplace_path: Path) -> None:
    if not marketplace_path.exists():
        return

    data = load_json_file(marketplace_path, {"plugins": []})
    plugins = data.get("plugins")
    if isinstance(plugins, list):
        data["plugins"] = [
            plugin
            for plugin in plugins
            if not (isinstance(plugin, dict) and plugin.get("name") == PLUGIN_NAME)
        ]
    write_json_file(marketplace_path, data)


def remove_cached_plugin(codex_home: Path) -> None:
    cache_root = codex_home / "plugins" / "cache"
    if not cache_root.exists():
        return
    for candidate in cache_root.glob(f"*/{PLUGIN_NAME}"):
        remove_path(candidate)


def install(args: argparse.Namespace) -> None:
    source_root = args.source_root.resolve()
    plugin_root = args.plugin_root.resolve()
    codex_home = args.codex_home.resolve()
    agents_home = args.agents_home.resolve()

    if not (source_root / ".codex-plugin" / "plugin.json").is_file():
        error(f"Missing plugin manifest under {source_root}")

    copy_tree_atomic(source_root, plugin_root)
    marketplace_path = agents_home / "plugins" / "marketplace.json"
    marketplace_name = merge_marketplace(marketplace_path, plugin_root, agents_home)
    cache_root = cache_plugin(plugin_root, codex_home, marketplace_name)
    plugin_key = f"{PLUGIN_NAME}@{marketplace_name}"
    marketplace_source_path = relative_marketplace_source_path(plugin_root, agents_home)
    update_config_for_install(codex_home / "config.toml", plugin_key)
    stop_hook_command = str(plugin_root / "scripts" / "stop-hook.sh")
    merge_hooks(codex_home / "hooks.json", stop_hook_command)

    summary = {
        "plugin_root": str(plugin_root),
        "marketplace_source_path": marketplace_source_path,
        "cache_root": str(cache_root),
        "marketplace_path": str(marketplace_path),
        "plugin_key": plugin_key,
        "hooks_path": str(codex_home / "hooks.json"),
        "config_path": str(codex_home / "config.toml"),
    }
    print(json.dumps(summary, indent=2))


def uninstall(args: argparse.Namespace) -> None:
    plugin_root = args.plugin_root.resolve()
    codex_home = args.codex_home.resolve()
    agents_home = args.agents_home.resolve()

    remove_plugin_from_marketplace(agents_home / "plugins" / "marketplace.json")
    remove_hooks(codex_home / "hooks.json", str(plugin_root / "scripts" / "stop-hook.sh"))
    update_config_for_uninstall(codex_home / "config.toml")
    remove_cached_plugin(codex_home)

    summary = {
        "plugin_root": str(plugin_root),
        "marketplace_path": str(agents_home / "plugins" / "marketplace.json"),
        "hooks_path": str(codex_home / "hooks.json"),
        "config_path": str(codex_home / "config.toml"),
        "cache_root": str(codex_home / "plugins" / "cache"),
    }
    print(json.dumps(summary, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Install or uninstall the Easy Loop Codex plugin.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--source-root", type=Path, required=True)
    install_parser.add_argument("--plugin-root", type=Path, required=True)
    install_parser.add_argument("--codex-home", type=Path, required=True)
    install_parser.add_argument("--agents-home", type=Path, required=True)

    uninstall_parser = subparsers.add_parser("uninstall")
    uninstall_parser.add_argument("--plugin-root", type=Path, required=True)
    uninstall_parser.add_argument("--codex-home", type=Path, required=True)
    uninstall_parser.add_argument("--agents-home", type=Path, required=True)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "install":
        install(args)
    elif args.command == "uninstall":
        uninstall(args)
    else:
        parser.error("Unknown command")


if __name__ == "__main__":
    main()
