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

    # Check readability
    if not os.access(path, os.R_OK):
        return (False, f"[error] no read permission: {path}")

    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except json.JSONDecodeError as e:
        return (False, f"[error] invalid JSON: {path} — {e}")
    except Exception as e:
        return (False, f"[error] failed to read: {path} — {e}")

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

    # Check writability; if not writable but we can escalate via passwordless
    # sudo, ask the caller to re-exec the whole script under sudo by
    # signalling a special return.
    if not os.access(path, os.W_OK):
        return (False, f"[need-elevate] {path}")

    backup = f"{path}.bak"
    try:
        if not os.path.exists(backup):
            shutil.copy2(path, backup)

        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent="\t")
            f.write("\n")
    except PermissionError:
        return (False, f"[error] permission denied writing to: {path}")
    except Exception as e:
        return (False, f"[error] failed to write: {path} — {e}")

    return (True, f"[ok] patched: {path}")


def discover_targets() -> list[str]:
    targets = set(TARGETS)
    for pattern in GLOB_PATTERNS:
        expanded = os.path.expanduser(pattern)
        for match in glob(expanded):
            targets.add(match)
    return sorted(targets)


def check_file(path: str) -> tuple[str, str]:
    """Return (state, message) where state is one of: patched, unpatched, n/a."""
    if not os.path.exists(path):
        return ("n/a", f"[skip] not found: {path}")

    if not os.access(path, os.R_OK):
        return ("n/a", f"[error] no read permission: {path}")

    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except json.JSONDecodeError as e:
        return ("n/a", f"[error] invalid JSON: {path} — {e}")
    except Exception as e:
        return ("n/a", f"[error] failed to read: {path} — {e}")

    providers = doc.get("contributes", {}).get("languageModelChatProviders", [])
    ollama_providers = [p for p in providers if p.get("vendor") == "ollama"]
    if not ollama_providers:
        return ("n/a", f"[skip] no ollama provider: {path}")

    for provider in ollama_providers:
        props = provider.get("configuration", {}).get("properties", {})
        if props.get("apiKey") != API_KEY_SCHEMA:
            return ("unpatched", f"[unpatched] {path}")

    return ("patched", f"[patched] {path}")


def run_check() -> int:
    patched = 0
    unpatched = 0
    seen = False

    for target in discover_targets():
        state, msg = check_file(target)
        if not msg.startswith("[skip]"):
            seen = True
        if state == "patched":
            patched += 1
        elif state == "unpatched":
            unpatched += 1
        print(msg)

    if not seen:
        print("[info] no known VS Code package.json paths found")
        return 0

    print(f"\n[summary] patched={patched} unpatched={unpatched}")
    return 1 if unpatched > 0 else 0


def main() -> int:
    if "--check" in sys.argv[1:] or "--status" in sys.argv[1:]:
        return run_check()


    patched_count = 0
    error_count = 0
    needs_elevate = False
    seen_any_target = False

    for target in discover_targets():
        changed, msg = patch_file(target)
        if not msg.startswith("[skip]"):
            seen_any_target = True

        if changed:
            patched_count += 1
        elif msg.startswith("[error]"):
            error_count += 1
        elif msg.startswith("[need-elevate]"):
            needs_elevate = True

        print(msg)

    if not seen_any_target:
        print("[info] no known VS Code package.json paths found; nothing to patch")
        return 0

    # If any root-owned target needed elevation, re-exec ourselves under
    # passwordless sudo (if available) and merge the results. This is
    # what makes the helper usable from systemd-run --user (which has no
    # root privileges on its own).
    if needs_elevate and not _already_elevated():
        import subprocess
        if os.path.exists("/usr/bin/sudo") and os.geteuid() != 0:
            rc = subprocess.call(["sudo", "-n", "python3", __file__, "--internal-elevated"] + sys.argv[1:])
            return rc

    if error_count > 0:
        print(f"\n[warn] {error_count} file(s) had permission/access issues; run with elevated privileges if needed")
        return 1 if patched_count == 0 else 0

    if patched_count > 0:
        print(f"\n[ok] successfully patched {patched_count} file(s)")

    return 0


def _already_elevated() -> bool:
    """Are we already running as root?"""
    return os.geteuid() == 0


if __name__ == "__main__":
    sys.exit(main())
