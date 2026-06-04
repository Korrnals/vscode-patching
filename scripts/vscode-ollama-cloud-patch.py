#!/usr/bin/env python3
"""Patch VS Code Copilot Chat manifest to add/update Ollama Cloud apiKey field."""

from __future__ import annotations

import json
import os
import shutil
import sys
from glob import glob
from typing import Any

TARGETS = [
    "/usr/share/code/resources/app/extensions/github.copilot-chat/package.json",
    "/usr/share/code/resources/app/extensions/copilot/package.json",
    "/usr/share/code-insiders/resources/app/extensions/github.copilot-chat/package.json",
    "/usr/share/code-insiders/resources/app/extensions/copilot/package.json",
]

GLOB_PATTERNS = [
    "~/.vscode-server/extensions/github.copilot-chat-*/package.json",
    "~/.vscode-server/extensions/copilot-*/package.json",
    "/root/.vscode-server/extensions/github.copilot-chat-*/package.json",
    "/root/.vscode-server/extensions/copilot-*/package.json",
    "/root/.vscode-server/cli/servers/*/server/extensions/github.copilot-chat/package.json",
    "/root/.vscode-server/cli/servers/*/server/extensions/copilot/package.json",
]

API_KEY_SCHEMA: dict[str, Any] = {
    "type": "string",
    "secret": True,
    "description": "API key for Ollama Cloud (https://ollama.com). Leave empty for local Ollama.",
    "title": "API Key",
}


def patch_file(path: str) -> tuple[bool, str]:
    if not os.path.exists(path):
        return (False, f"[skip] not found: {path}")

    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)

    changed = False
    providers = doc.get("contributes", {}).get("languageModelChatProviders", [])

    for provider in providers:
        if provider.get("vendor") != "ollama":
            continue

        props = provider.setdefault("configuration", {}).setdefault("properties", {})
        if props.get("apiKey") != API_KEY_SCHEMA:
            props["apiKey"] = API_KEY_SCHEMA
            changed = True

    if not changed:
        return (False, f"[ok] already patched: {path}")

    backup = f"{path}.bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent="\t")
        f.write("\n")

    return (True, f"[ok] patched: {path}")


def discover_targets() -> list[str]:
    targets = set(TARGETS)
    for pattern in GLOB_PATTERNS:
        expanded = os.path.expanduser(pattern)
        for match in glob(expanded):
            targets.add(match)
    return sorted(targets)


def main() -> int:
    patched_any = False
    seen_any_target = False

    for target in discover_targets():
        changed, msg = patch_file(target)
        if not msg.startswith("[skip]"):
            seen_any_target = True
        patched_any = patched_any or changed
        print(msg)

    if not seen_any_target:
        print("[info] no known VS Code package.json paths found; nothing to patch")

    return 0


if __name__ == "__main__":
    sys.exit(main())
