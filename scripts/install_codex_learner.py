#!/usr/bin/env python3
"""Install Engram's Codex lifecycle hooks without changing other Codex settings.

The installed runtime is immutable and content addressed. Changing it changes
the hook definition, so Codex's normal /hooks trust review applies to upgrades.
No trust state is written here. Uninstall removes registrations, not memories,
queued work, runtime versions, or backups. Requires Python 3.11 or newer.
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile
import tomllib
import uuid
from contextlib import contextmanager
from typing import Any

EVENTS = ("Stop", "PreCompact", "SessionEnd")
REQUIRED_ASSETS = (
    "codex_learner.py",
    "codex_learner/__init__.py",
    "codex_learner/transcript.py",
    "codex_learner/runner.py",
    "codex_learner/memory_proxy.py",
    "codex_learner/learner_prompt.md",
)
OPTIONAL_ASSETS: tuple[str, ...] = ()
ABSENT_SHA = "absent"


class InstallError(Exception):
    """An unsafe or incomplete installation was rejected."""


def digest(data: bytes | None) -> str:
    return ABSENT_SHA if data is None else hashlib.sha256(data).hexdigest()


def read_regular(path: Path) -> bytes | None:
    if path.is_symlink():
        raise InstallError(f"Refusing symlink: {path}")
    try:
        mode = path.stat().st_mode
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(mode):
        raise InstallError(f"Expected regular file: {path}")
    return path.read_bytes()


def json_object(raw: bytes | None, path: Path) -> dict[str, Any]:
    if raw is None:
        return {}
    try:
        def no_duplicates(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError(f"duplicate key {key!r}")
                result[key] = value
            return result
        result = json.loads(raw, object_pairs_hook=no_duplicates)
    except (ValueError, UnicodeError) as exc:
        raise InstallError(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(result, dict):
        raise InstallError(f"Expected JSON object: {path}")
    return result


def encode(value: Any) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def private_directory(path: Path) -> None:
    if path.is_symlink():
        raise InstallError(f"Refusing symlink directory: {path}")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise InstallError(f"Expected directory: {path}")
    path.chmod(0o700)


def atomic_write(path: Path, data: bytes, expected: bytes | None) -> None:
    """Atomic replace, with a last-moment stale-write check.

    The installer lock serializes this installer's writers. Editors do not
    necessarily honor that lock, so reject changes observed before replacement.
    """
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if read_regular(path) != expected:
            raise InstallError(f"Concurrent change detected; retry: {path}")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def install_lock(state_dir: Path):
    private_directory(state_dir)
    lock_path = state_dir / "install.lock"
    if lock_path.is_symlink():
        raise InstallError(f"Refusing symlink: {lock_path}")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def load_assets(source_dir: Path) -> dict[str, bytes]:
    result = {}
    for name in REQUIRED_ASSETS + OPTIONAL_ASSETS:
        data = read_regular(source_dir / name)
        if data is None:
            if name in REQUIRED_ASSETS:
                raise InstallError(f"Missing runtime asset: {source_dir / name}")
            continue
        if name.endswith(".py"):
            try:
                compile(data, name, "exec")
            except SyntaxError as exc:
                raise InstallError(f"Invalid Python runtime asset {name}: {exc}") from exc
        result[name] = data
    return result


def asset_digest(assets: dict[str, bytes]) -> str:
    content = [[name, hashlib.sha256(data).hexdigest()] for name, data in sorted(assets.items())]
    return hashlib.sha256(encode(content)).hexdigest()


def hook_command(python: Path, runtime_dir: Path, state_dir: Path) -> str:
    return shlex.join([str(python), str(runtime_dir / "codex_learner.py"), "hook", "--state-dir", str(state_dir)])


def registrations(command: str) -> dict[str, list[dict[str, Any]]]:
    return {event: [{"hooks": [{"type": "command", "command": command, "timeout": 3}]}] for event in EVENTS}


def owned_commands(manifest: dict[str, Any]) -> set[str]:
    values = manifest.get("owned_commands", [])
    if not isinstance(values, list) or any(not isinstance(x, str) for x in values):
        raise InstallError("Invalid install manifest owned_commands")
    return set(values)


def points_into_runtime(command: str, state_dir: Path) -> bool:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    prefix = str(state_dir / "runtime") + os.sep
    return any(token.startswith(prefix) and token.endswith("/codex_learner.py") for token in tokens)


def merge_hooks(
    existing: dict[str, Any], commands: set[str], state_dir: Path, new_command: str | None
) -> dict[str, Any]:
    result = copy.deepcopy(existing)
    hooks = result.get("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError("hooks.json 'hooks' must be an object")
    hooks = copy.deepcopy(hooks)
    for event in EVENTS:
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise InstallError(f"hooks.{event} must be an array")
        updated = []
        found = False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise InstallError(f"Malformed hooks.{event} group")
            handlers = []
            for handler in group["hooks"]:
                if not isinstance(handler, dict):
                    raise InstallError(f"Malformed hooks.{event} handler")
                command = handler.get("command")
                if isinstance(command, str) and command in commands:
                    if new_command is not None and not found:
                        refreshed = dict(handler, command=new_command)
                        timeout = refreshed.get("timeout", 3)
                        if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or timeout <= 0:
                            raise InstallError(f"Invalid owned hook timeout for {event}")
                        refreshed["timeout"] = min(timeout, 3) if event == "SessionEnd" else max(timeout, 3)
                        handlers.append(refreshed)
                        found = True
                else:
                    if isinstance(command, str) and points_into_runtime(command, state_dir):
                        raise InstallError(f"Engram runtime command was edited or ownership manifest is missing ({event}); review it before installation")
                    handlers.append(handler)
            if handlers:
                updated.append(dict(group, hooks=handlers))
            elif not group["hooks"]:
                updated.append(group)  # Preserve pre-existing empty groups.
        if new_command is not None and not found:
            updated.extend(registrations(new_command)[event])
        if updated:
            hooks[event] = updated
        else:
            hooks.pop(event, None)
    if hooks:
        result["hooks"] = hooks
    else:
        result.pop("hooks", None)
    return result


def stage_runtime(state_dir: Path, assets: dict[str, bytes]) -> Path:
    parent = state_dir / "runtime"
    private_directory(parent)
    destination = parent / asset_digest(assets)
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink():
            raise InstallError(f"Refusing symlink: {destination}")
        for name, content in assets.items():
            if read_regular(destination / name) != content:
                raise InstallError(f"Installed runtime changed: {destination / name}")
        return destination
    staging = Path(tempfile.mkdtemp(prefix=".stage-", dir=parent))
    try:
        for name, content in assets.items():
            output = staging / name
            private_directory(output.parent)
            atomic_write(output, content, None)
        os.rename(staging, destination)
    finally:
        if staging.exists():
            # Remove only this invocation's staging files.
            for child in sorted(staging.rglob("*"), key=lambda x: len(x.parts), reverse=True):
                child.unlink() if child.is_file() else child.rmdir()
            staging.rmdir()
    return destination


def prepare(codex_home: Path, state_dir: Path, source_dir: Path, python: Path) -> dict[str, Any]:
    assets = load_assets(source_dir)
    if not python.is_file() or not os.access(python, os.X_OK):
        raise InstallError(f"Python executable is unavailable: {python}")
    hooks_path = codex_home / "hooks.json"
    raw = read_regular(hooks_path)
    existing = json_object(raw, hooks_path)
    manifest_path = state_dir / "install.json"
    manifest = json_object(read_regular(manifest_path), manifest_path)
    if manifest and (manifest.get("version") != 1 or manifest.get("hooks_path") != str(hooks_path)):
        raise InstallError("Install manifest version or hooks.json location does not match")
    runtime = state_dir / "runtime" / asset_digest(assets)
    command = hook_command(python, runtime, state_dir)
    commands = owned_commands(manifest) | {command}
    merged = merge_hooks(existing, commands, state_dir, command)
    return {
        "hooks_path": str(hooks_path), "state_dir": str(state_dir),
        "runtime_dir": str(runtime), "runtime_sha256": asset_digest(assets),
        "expected_sha256": digest(raw), "changed": existing != merged,
        "fragment": {"hooks": registrations(command)}, "merged_hooks": merged,
        "owned_commands": sorted(commands),
        "activation": "Review and trust these exact hooks using Codex /hooks; installer does not grant trust.",
    }


def backup(state_dir: Path, raw: bytes | None, operation: str) -> str:
    directory = state_dir / "backups"
    private_directory(directory)
    name = f"{operation}-{uuid.uuid4().hex}.json"
    path = directory / name
    # A manifest distinguishes an absent file from a present empty object.
    atomic_write(path, encode({"hooks_existed": raw is not None, "hooks_sha256": digest(raw), "hooks_content": raw.decode() if raw is not None else None}), None)
    return str(path)


def memory_registration_plan(codex_home: Path, memory_command: Path) -> tuple[bytes | None, bytes | None]:
    """Return a surgical append, or None when any memory registration exists.

    Existing disabled, custom, or invalid registrations remain the user's own.
    Inline-table layouts which cannot be extended are rejected, not rewritten.
    """
    path = codex_home / "config.toml"
    raw = read_regular(path)
    try:
        config = tomllib.loads(raw.decode() if raw is not None else "")
    except (ValueError, UnicodeError) as exc:
        raise InstallError(f"Cannot read Codex config: {exc}") from exc
    servers = config.get("mcp_servers", {})
    if not isinstance(servers, dict):
        raise InstallError("Codex mcp_servers must be a table")
    if "memory" in servers:
        return raw, None
    if not memory_command.is_file() or not os.access(memory_command, os.X_OK):
        raise InstallError(f"Memory executable is unavailable: {memory_command}")
    # JSON string escaping is also valid for this TOML basic string.
    block = ('\n# Engram memory server (Codex learner installer)\n[mcp_servers.memory]\ncommand = ' + json.dumps(str(memory_command), ensure_ascii=True) + '\n').encode()
    merged = (raw or b"") + block
    try:
        parsed = tomllib.loads(merged.decode())
    except (ValueError, UnicodeError) as exc:
        raise InstallError("Cannot safely append memory MCP registration to this TOML layout; register memory with Codex before retrying") from exc
    expected = copy.deepcopy(config)
    expected.setdefault("mcp_servers", {})["memory"] = {"command": str(memory_command)}
    if parsed != expected:
        raise InstallError("Memory MCP append would change unrelated Codex settings")
    return raw, merged


def config_backup(state_dir: Path, raw: bytes | None) -> str:
    directory = state_dir / "backups"
    private_directory(directory)
    path = directory / f"memory-config-{uuid.uuid4().hex}.json"
    atomic_write(path, encode({"file": "config.toml", "existed": raw is not None, "sha256": digest(raw), "content": raw.decode() if raw is not None else None}), None)
    return str(path)


def register_memory(codex_home: Path, state_dir: Path, memory_command: Path) -> dict[str, Any]:
    raw, merged = memory_registration_plan(codex_home, memory_command)
    if merged is None:
        return {"status": "existing_registration_preserved"}
    backup_path = config_backup(state_dir, raw)
    manifest_path = state_dir / "install.json"
    manifest_raw = read_regular(manifest_path)
    manifest = json_object(manifest_raw, manifest_path)
    manifest["memory_mcp"] = {"command": str(memory_command), "block": merged[len(raw or b""):].decode()}
    atomic_write(manifest_path, encode(manifest), manifest_raw)
    atomic_write(codex_home / "config.toml", merged, raw)
    return {"status": "registered", "backup": backup_path}


def unregister_memory(codex_home: Path, state_dir: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    owned = manifest.get("memory_mcp")
    if not isinstance(owned, dict) or not isinstance(owned.get("block"), str) or not isinstance(owned.get("command"), str):
        return {"status": "not_owned"}
    path = codex_home / "config.toml"
    raw = read_regular(path)
    if raw is None:
        return {"status": "already_absent"}
    try:
        config = tomllib.loads(raw.decode())
    except (ValueError, UnicodeError) as exc:
        raise InstallError(f"Cannot read Codex config for unregister: {exc}") from exc
    servers = config.get("mcp_servers", {})
    if not isinstance(servers, dict) or "memory" not in servers:
        return {"status": "already_absent"}
    block = owned["block"].encode()
    if servers["memory"] != {"command": owned["command"]} or raw.count(block) != 1:
        return {"status": "modified_registration_preserved"}
    merged = raw.replace(block, b"", 1)
    try:
        after = tomllib.loads(merged.decode())
    except (ValueError, UnicodeError):
        return {"status": "modified_registration_preserved"}
    # Table headers may have been added below ours. Compare every other setting
    # after removing the owned leaf; never remove a block that changes scope.
    expected = copy.deepcopy(config)
    expected["mcp_servers"].pop("memory")
    if not expected["mcp_servers"] and "mcp_servers" not in after:
        expected.pop("mcp_servers")
    if after != expected:
        return {"status": "modified_registration_preserved"}
    backup_path = config_backup(state_dir, raw)
    atomic_write(path, merged, raw)
    return {"status": "unregistered", "backup": backup_path}


def install(codex_home: Path, state_dir: Path, source_dir: Path, python: Path, expected_sha256: str | None = None, memory_command: Path | None = None) -> dict[str, Any]:
    if codex_home.is_symlink():
        raise InstallError(f"Refusing symlink directory: {codex_home}")
    codex_home.mkdir(parents=True, exist_ok=True, mode=0o700)
    with install_lock(state_dir):
        plan = prepare(codex_home, state_dir, source_dir, python)
        if expected_sha256 is not None and plan["expected_sha256"] != expected_sha256:
            raise InstallError("hooks.json changed since preparation; review a fresh plan")
        if memory_command is not None:
            memory_registration_plan(codex_home, memory_command)  # Validate before modifying hooks.
        assets = load_assets(source_dir)
        if asset_digest(assets) != plan["runtime_sha256"]:
            raise InstallError("Runtime source changed during preparation; retry")
        stage_runtime(state_dir, assets)
        hooks_path = codex_home / "hooks.json"
        raw = read_regular(hooks_path)
        if digest(raw) != plan["expected_sha256"]:
            raise InstallError("hooks.json changed during preparation; retry")
        manifest_path = state_dir / "install.json"
        old_manifest = read_regular(manifest_path)
        manifest = {
            "version": 1, "hooks_path": str(hooks_path), "runtime_dir": plan["runtime_dir"],
            "runtime_sha256": plan["runtime_sha256"], "owned_commands": plan["owned_commands"],
        }
        prior = json_object(old_manifest, manifest_path)
        if "memory_mcp" in prior:
            manifest["memory_mcp"] = prior["memory_mcp"]
        backup_path = backup(state_dir, raw, "install") if plan["changed"] else None
        # Record both previous and next commands before replacing hooks.json.
        # An interrupted update can therefore be retried or uninstalled safely.
        if json_object(old_manifest, manifest_path) != manifest:
            atomic_write(manifest_path, encode(manifest), old_manifest)
        if plan["changed"]:
            atomic_write(hooks_path, encode(plan["merged_hooks"]), raw)
        memory_result = register_memory(codex_home, state_dir, memory_command) if memory_command is not None else {"status": "not_requested"}
        return {"status": "installed" if plan["changed"] else "unchanged", "backup": backup_path, "memory_mcp": memory_result, **{k: v for k, v in plan.items() if k not in ("merged_hooks", "owned_commands")}}


def uninstall(codex_home: Path, state_dir: Path, expected_sha256: str | None = None) -> dict[str, Any]:
    manifest_path = state_dir / "install.json"
    if read_regular(manifest_path) is None:
        return {"status": "not_installed", "preserved_state_dir": str(state_dir)}
    with install_lock(state_dir):
        manifest = json_object(read_regular(manifest_path), manifest_path)
        hooks_path = codex_home / "hooks.json"
        if manifest.get("hooks_path") != str(hooks_path):
            raise InstallError("Install manifest belongs to a different hooks.json")
        raw = read_regular(hooks_path)
        if expected_sha256 is not None and digest(raw) != expected_sha256:
            raise InstallError("hooks.json changed since preparation; review a fresh plan")
        existing = json_object(raw, hooks_path)
        merged = merge_hooks(existing, owned_commands(manifest), state_dir, None)
        changed = merged != existing
        backup_path = backup(state_dir, raw, "uninstall") if changed else None
        if changed:
            atomic_write(hooks_path, encode(merged), raw)
        memory_result = unregister_memory(codex_home, state_dir, manifest)
        return {"status": "uninstalled" if changed or memory_result["status"] == "unregistered" else "unchanged", "backup": backup_path, "memory_mcp": memory_result, "preserved_state_dir": str(state_dir)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "install", "uninstall"))
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser())
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--python", type=Path, default=Path(sys.executable))
    parser.add_argument("--memory-command", type=Path, help="Register this memory MCP executable only if absent; uninstall removes only our unchanged registration")
    parser.add_argument("--expected-sha256", help="Reject a hooks.json changed since prepare (use 'absent' for a missing file)")
    args = parser.parse_args(argv)
    codex_home = args.codex_home.expanduser().absolute()
    state_dir = (args.state_dir or codex_home / "engram-learner").expanduser().absolute()
    try:
        if args.action == "uninstall":
            result = uninstall(codex_home, state_dir, args.expected_sha256)
        else:
            if args.source_dir is None:
                parser.error("--source-dir is required for prepare/install")
            values = (codex_home, state_dir, args.source_dir.expanduser().absolute(), args.python.expanduser().absolute())
            memory_command = args.memory_command.expanduser().absolute() if args.memory_command is not None else None
            if args.action == "prepare":
                result = prepare(*values)
                if memory_command is not None:
                    raw, merged = memory_registration_plan(codex_home, memory_command)
                    result["memory_mcp"] = {"status": "would_register" if merged is not None else "existing_registration_preserved", "config_sha256": digest(raw), "command": str(memory_command) if merged is not None else None}
            else:
                result = install(*values, args.expected_sha256, memory_command)
        print(json.dumps(result, indent=2))
        return 0
    except (InstallError, OSError) as exc:
        print(f"Engram Codex learner: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
