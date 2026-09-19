"""Read the effective memory MCP declaration without launching any process.

Global memory wins, including an explicitly disabled global declaration. Otherwise
read this package's .mcp.json and apply its exact Codex plugin policy overlay.
Only stdio is supported. Approval checks are intentionally stricter than an
interactive client: unattended hooks require explicit ``approve``.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import tomllib

MAX_CONFIG = 1024 * 1024
MAX_PLUGIN = 65536
MODES = {"auto", "prompt", "writes", "approve"}
PLUGIN_NAME = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*")
MARKETPLACE_NAME = re.compile(r"[A-Za-z0-9_-]+")
TRANSPORT_KEYS = ("command", "args", "env", "env_vars", "cwd",
                  "startup_timeout_sec", "tool_timeout_sec")


def read_bytes(path: Path, limit: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("memory_config_not_regular")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("memory_config_oversize")
    return data


def _object(value):
    if not isinstance(value, dict):
        raise ValueError("memory_config_invalid")
    return value


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("memory_config_duplicate_key")
        value[key] = item
    return value


def _string(value, *, nonempty=True):
    if not isinstance(value, str) or (nonempty and not value) or len(value) > 4096 or "\0" in value:
        raise ValueError("memory_config_invalid")
    return value


def _strings(value, limit=512):
    if not isinstance(value, list) or len(value) > limit:
        raise ValueError("memory_config_invalid")
    return [_string(item) for item in value]


def _enabled(value):
    if type(value) is not bool:
        raise ValueError("memory_config_invalid")
    return value


def _mode(value):
    if not isinstance(value, str) or value not in MODES:
        raise ValueError("memory_config_invalid")
    return value


def _limit(value):
    if type(value) is not int or value <= 0:
        raise ValueError("memory_config_invalid")
    return value


def _tool_policies(value):
    value = _object(value)
    if len(value) > 512:
        raise ValueError("memory_config_invalid")
    result = {}
    for name, policy in value.items():
        _string(name)
        policy = _object(policy)
        item = {}
        if "approval_mode" in policy:
            item["approval_mode"] = _mode(policy["approval_mode"])
        if "output_token_limit" in policy:
            item["output_token_limit"] = _limit(policy["output_token_limit"])
        result[name] = item
    return result


def _overlay(memory, policy):
    """Match the personal plugin loader's supplied-field replacement semantics."""
    policy = _object(policy)
    memory["enabled"] = _enabled(policy.get("enabled", True))
    for key in ("default_tools_approval_mode", "enabled_tools", "disabled_tools"):
        if key in policy:
            memory[key] = policy[key]
    tools = _tool_policies(memory.get("tools", {}))
    for name, item in _tool_policies(policy.get("tools", {})).items():
        old = tools.setdefault(name, {})
        if "approval_mode" in item:
            old["approval_mode"] = item["approval_mode"]
        if "output_token_limit" in item:
            old["output_token_limit"] = min(old.get("output_token_limit", item["output_token_limit"]),
                                             item["output_token_limit"])
    memory["tools"] = tools


def _normalize(memory, *, plugin_root=None):
    memory = _object(memory)
    if memory.get("environment_id") is not None:
        raise ValueError("memory_config_requires_local_environment")
    if "url" in memory or memory.get("type", "stdio") != "stdio":
        raise ValueError("memory_config_requires_stdio")
    result = {"enabled": _enabled(memory.get("enabled", True)),
              "default_tools_approval_mode": _mode(memory.get("default_tools_approval_mode", "auto")),
              "tools": _tool_policies(memory.get("tools", {})),
              "disabled_tools": sorted(set(_strings(memory.get("disabled_tools", []))))}
    if "enabled_tools" in memory:
        result["enabled_tools"] = sorted(set(_strings(memory["enabled_tools"])))
    command = _string(memory.get("command"))
    cwd = memory.get("cwd")
    if cwd is not None:
        cwd = Path(_string(cwd))
        if not cwd.is_absolute():
            if plugin_root is None:
                raise ValueError("memory_config_relative_cwd")
            cwd = plugin_root / cwd
        # Codex roots only cwd. Resolve the executable against that exact cwd;
        # arguments and environment values stay literal (no shell expansion).
        cwd = cwd.resolve()
        result["cwd"] = str(cwd)
    if not Path(command).is_absolute():
        if cwd is None or "/" not in command:
            raise ValueError("memory_config_unbound_command")
        command = str((cwd / command).absolute())
    result["command"] = command
    result["args"] = [_string(item, nonempty=False) for item in memory.get("args", [])] if isinstance(memory.get("args", []), list) else None
    if result["args"] is None or len(result["args"]) > 32:
        raise ValueError("memory_config_invalid")
    env = _object(memory.get("env", {}))
    if len(env) > 32:
        raise ValueError("memory_config_invalid")
    result["env"] = {}
    for key, value in env.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,100}", key):
            raise ValueError("memory_config_invalid")
        result["env"][key] = _string(value, nonempty=False)
    names = _strings(memory.get("env_vars", []), 32)
    if any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,100}", key) for key in names):
        raise ValueError("memory_config_invalid")
    result["env_vars"] = sorted(set(names))
    for key in ("startup_timeout_sec", "tool_timeout_sec"):
        if key in memory:
            value = memory[key]
            if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise ValueError("memory_config_invalid")
            result[key] = value
    return result


def _plugin_identity(plugins: dict, plugin_root: Path) -> str:
    """Bind installed packages to their cache namespace; reject source ambiguity.

    Codex caches local marketplace packages at plugins/cache/MARKETPLACE/NAME/VERSION.
    Resolve symlinks before deriving that identity, and never let another enabled
    marketplace override a disabled or absent policy for the executing package.
    A source checkout has no cache namespace: require one matching configured ID,
    counting disabled entries too rather than guessing which marketplace owns it.
    """
    manifest = _object(json.loads(read_bytes(
        plugin_root / ".codex-plugin" / "plugin.json", MAX_PLUGIN), object_pairs_hook=_pairs))
    name = _string(manifest.get("name"))
    version = _string(manifest.get("version"))
    if (len(name) > 64 or PLUGIN_NAME.fullmatch(name) is None
            or len(version) > 256 or version in {".", ".."}
            or "/" in version or "\\" in version):
        raise ValueError("memory_plugin_identity_invalid")

    parts = plugin_root.parts
    markers = [i for i in range(len(parts) - 1)
               if parts[i:i + 2] == ("plugins", "cache")]
    if markers:
        tail = parts[markers[-1] + 2:]
        if (len(markers) != 1 or len(tail) != 3
                or MARKETPLACE_NAME.fullmatch(tail[0]) is None
                or tail[1:] != (name, version)):
            raise ValueError("memory_plugin_identity_invalid")
        identity = name + "@" + tail[0]
        if identity not in plugins:
            raise ValueError("memory_plugin_disabled")
        return identity

    candidates = []
    for identity in plugins:
        candidate, separator, marketplace = identity.partition("@")
        if candidate != name:
            continue
        if (not separator or len(marketplace) > 128
                or MARKETPLACE_NAME.fullmatch(marketplace) is None):
            raise ValueError("memory_plugin_identity_invalid")
        candidates.append(identity)
    if not candidates:
        raise ValueError("memory_plugin_disabled")
    if len(candidates) != 1:
        raise ValueError("memory_plugin_identity_ambiguous")
    return candidates[0]


def resolve(config_path: Path, plugin_root: Path, *, config_bytes: bytes | None = None) -> tuple[dict, dict]:
    """Return parsed user config and canonical effective memory, never a fallback on error."""
    if not config_path.is_absolute() or not plugin_root.is_absolute():
        raise ValueError("memory_config_absolute_path_required")
    if config_bytes is None:
        config_bytes = read_bytes(config_path, MAX_CONFIG)
    if not isinstance(config_bytes, bytes) or len(config_bytes) > MAX_CONFIG:
        raise ValueError("memory_config_invalid_bytes")
    user = tomllib.loads(config_bytes.decode("utf-8"))
    servers = _object(user.get("mcp_servers", {}))
    if "memory" in servers:
        return user, _normalize(servers["memory"])
    if not _enabled(_object(user.get("features", {})).get("plugins", True)):
        raise ValueError("memory_plugin_disabled")
    plugins = _object(user.get("plugins", {}))
    plugin_root = plugin_root.resolve(strict=True)
    identity = _plugin_identity(plugins, plugin_root)
    plugin = _object(plugins[identity])
    if not _enabled(plugin.get("enabled", True)):
        raise ValueError("memory_plugin_disabled")
    package = _object(json.loads(read_bytes(plugin_root / ".mcp.json", MAX_PLUGIN), object_pairs_hook=_pairs))
    memory = _normalize(copy.deepcopy(_object(_object(package.get("mcpServers", {})).get("memory"))),
                        plugin_root=plugin_root)
    policies = _object(plugin.get("mcp_servers", {}))
    if "memory" in policies:
        _overlay(memory, policies["memory"])
    return user, _normalize(memory, plugin_root=plugin_root)


def fingerprint(memory: dict) -> str:
    """Pin effective memory configuration only, excluding project/model settings."""
    return hashlib.sha256(json.dumps(memory, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False, allow_nan=False).encode("utf-8")).hexdigest()


def allowed_tools(memory: dict, candidates) -> set[str]:
    if not memory["enabled"]:
        return set()
    allowed = set(candidates)
    if "enabled_tools" in memory:
        allowed.intersection_update(memory["enabled_tools"])
    allowed.difference_update(memory["disabled_tools"])
    return {name for name in allowed if memory["tools"].get(name, {}).get(
        "approval_mode", memory["default_tools_approval_mode"]) == "approve"}


def transport(memory: dict) -> dict:
    return {key: memory[key] for key in TRANSPORT_KEYS if key in memory}
