"""Select the installed Codex plugin at entry, before input or worker ownership.

The CLI's installed registry and enabled user policy are authority; marketplace
source versions and neighboring cache directories are not. Explicit source
checkouts retain their selected-source behavior. This cannot redirect a process
running an older package that predates this entry-point routing.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
import tomllib

HOP = "ENGRAM_RUNTIME_ROUTED"
HOOK_DEADLINE = "ENGRAM_RUNTIME_HOOK_DEADLINE"
DISCOVERY_SECONDS = 0.5
MAX_OUTPUT = 256 * 1024
NAME = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
                     r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
                     r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


class Refused(ValueError):
    """Only fixed codes from this module may be exposed by the entry points."""


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def codex_binary(config):
    # Same selection as the learner provider; do not choose another account/CLI.
    binary = config.get("codex_bin")
    if not binary:
        for applications in (Path("/Applications"), Path.home() / "Applications"):
            for app in ("ChatGPT.app", "Codex.app"):
                candidate = applications / app / "Contents/Resources/codex"
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    binary = str(candidate)
                    break
            if binary:
                break
    if not binary:
        binary = shutil.which("codex")
    if not binary:
        candidate = Path.home() / ".local/bin/codex"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            binary = str(candidate)
    if not binary:
        raise ValueError("codex_binary_not_found")
    return binary


def _identity(info):
    if stat.S_ISDIR(info.st_mode):
        # Unrelated cache/log entries can change without replacing this directory.
        return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _owned(path, *, directory=False):
    info = path.lstat()
    require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            and info.st_uid == os.getuid() and not info.st_mode & 0o022
            and (directory or info.st_nlink == 1), "routing_unsafe_path")
    return _identity(info)


def _read(path, limit, pins):
    before = _owned(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        require(_identity(os.fstat(stream.fileno())) == before, "routing_path_changed")
        raw = stream.read(limit + 1)
        require(_identity(os.fstat(stream.fileno())) == before, "routing_path_changed")
    require(len(raw) <= limit, "routing_input_limit")
    require(_owned(path) == before, "routing_path_changed")
    pins[path] = before
    return raw


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "routing_invalid_metadata")
        value[key] = item
    return value


def _json(raw):
    return json.loads(raw, object_pairs_hook=_pairs)


def _version(value):
    require(isinstance(value, str) and len(value) <= 128, "routing_invalid_version")
    match = VERSION.fullmatch(value)
    require(match is not None, "routing_invalid_version")
    major, minor, patch, pre, _ = match.groups()
    identifiers = pre.split(".") if pre is not None else []
    require(all(not (v.isdigit() and len(v) > 1 and v[0] == "0") for v in identifiers),
            "routing_invalid_version")
    # SemVer: releases follow prereleases; numeric identifiers precede strings.
    return (int(major), int(minor), int(patch), pre is None,
            tuple((0, int(v)) if v.isdigit() else (1, v) for v in identifiers))


def _discover(binary, market, home, env):
    deadline = time.monotonic() + DISCOVERY_SECONDS
    child = subprocess.Popen([binary, "plugin", "list", "--marketplace", market, "--json"],
                             cwd=home, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True, close_fds=True)
    chunks = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        with selectors.DefaultSelector() as selector:
            for name in chunks:
                stream = getattr(child, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                require(remaining > 0, "routing_discovery_timeout")
                for key, _ in selector.select(remaining):
                    data = os.read(key.fileobj.fileno(), 4096)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    output = chunks[key.data]
                    output.extend(data)
                    require(len(output) <= (MAX_OUTPUT if key.data == "stdout" else 8192),
                            "routing_discovery_output_limit")
            try:
                code = child.wait(timeout=max(0.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise Refused("routing_discovery_timeout") from None
            require(code == 0, "routing_discovery_failed")
        return _json(chunks["stdout"])
    finally:
        try:
            if child.returncode is None:
                # Do not poll/reap first: even an exited parent must keep its PID
                # anchored while we kill descendants holding inherited pipes.
                # Own session only. Never wait on a potentially blocked pipe reader.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    raise Refused("routing_discovery_cleanup_timeout") from None
        finally:
            child.stdout.close()
            child.stderr.close()


def _directories(path, ancestor, pins):
    require(path.is_relative_to(ancestor) and path.resolve(strict=True) == path,
            "routing_unsafe_path")
    for item in (ancestor, *reversed(path.relative_to(ancestor).parents[:-1])):
        # Relative parents are joined below; the root is already absolute.
        directory = item if item.is_absolute() else ancestor / item
        pins[directory] = _owned(directory, directory=True)
    pins[path] = _owned(path, directory=True)


def _package(root, name, version, pins):
    _directories(root / ".codex-plugin", root, pins)
    manifest = _json(_read(root / ".codex-plugin/plugin.json", 65536, pins))
    require(isinstance(manifest, dict) and manifest.get("name") == name
            and manifest.get("version") == version, "routing_manifest_mismatch")
    _version(version)


def _runtime_files(root, pins):
    scripts = root / "scripts"
    _directories(scripts, root, pins)
    # Python can import sibling modules before reaching an entry-point guard.
    # Check its bounded source closure, not native models or unrelated caches.
    count = 0
    for parent, directories, files in os.walk(scripts, followlinks=False):
        require(len(Path(parent).relative_to(scripts).parts) <= 4, "routing_input_limit")
        count += len(directories) + len(files)
        require(count <= 256, "routing_input_limit")
        for name in directories:
            path = Path(parent) / name
            pins[path] = _owned(path, directory=True)
        for name in files:
            path = Path(parent) / name
            pins[path] = _owned(path)


def successor(plugin_root, *, home, settings_path=None, environ=None):
    """Return the authenticated selected package and recheckable input identities."""
    plugin_root, home = Path(plugin_root).absolute(), Path(home).absolute()
    cache = home / "plugins/cache"
    if not plugin_root.is_relative_to(cache):
        return None  # Explicit source checkouts remain explicitly selected.
    parts = plugin_root.relative_to(cache).parts
    require(len(parts) == 3, "routing_invalid_cache_layout")
    market, name, version = parts
    require(NAME.fullmatch(market) is not None and name == "engram", "routing_invalid_cache_layout")
    pins = {}
    _directories(plugin_root, home, pins)
    _package(plugin_root, name, version, pins)
    config_path = home / "config.toml"
    config = tomllib.loads(_read(config_path, 1024 * 1024, pins).decode())
    plugin_id = name + "@" + market
    require(config.get("features", {}).get("plugins", True) is True
            and config.get("plugins", {}).get(plugin_id, {}).get("enabled") is True,
            "routing_plugin_disabled")
    settings = {}
    if settings_path is not None and (settings_path.exists() or settings_path.is_symlink()):
        _directories(settings_path.parent, settings_path.parent, pins)
        settings = _json(_read(settings_path, 65536, pins))
        require(isinstance(settings, dict), "routing_invalid_metadata")
    binary = codex_binary(settings)
    require(isinstance(binary, str) and bool(binary) and "\0" not in binary,
            "routing_invalid_cli")
    executable = Path(shutil.which(binary) or binary).resolve(strict=True)
    info = executable.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid in {0, os.getuid()}
            and not info.st_mode & 0o022 and os.access(executable, os.X_OK), "routing_invalid_cli")
    pins[executable] = _identity(info)
    value = _discover(str(executable), market, home, dict(os.environ if environ is None else environ))
    require(isinstance(value, dict) and isinstance(value.get("installed"), list)
            and len(value["installed"]) <= 512, "routing_invalid_registry")
    rows = [row for row in value["installed"] if isinstance(row, dict) and row.get("pluginId") == plugin_id]
    require(len(rows) == 1, "routing_ambiguous_selection")
    row = rows[0]
    require(row.get("name") == name and row.get("marketplaceName") == market
            and row.get("installed") is True and row.get("enabled") is True,
            "routing_selection_disabled")
    selected = row.get("version")
    require(_version(selected) >= _version(version), "routing_downgrade_refused")
    require(selected == version or _version(selected) > _version(version), "routing_ambiguous_version")
    target = cache / market / name / selected
    _directories(target, home, pins)
    _package(target, name, selected, pins)
    _runtime_files(target, pins)
    return target, pins


def hook_deadline(start):
    """An inherited hint can only shorten this process's own hook budget."""
    deadline = start + 2.8
    if HOP in os.environ and HOOK_DEADLINE in os.environ:
        try:
            inherited = float(os.environ[HOOK_DEADLINE])
        except (ValueError, TypeError):
            raise Refused("routing_invalid_deadline") from None
        require(math.isfinite(inherited), "routing_invalid_deadline")
        deadline = min(deadline, inherited)
    require(deadline > start, "routing_hook_deadline")
    return deadline


def maybe_exec(plugin_root, script_name, argv, *, state_root=None, deadline=None, allow_handoff=True):
    """Same-PID handoff before stdin, state mutation, or worker lock acquisition."""
    try:
        home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser().absolute()
        chosen = successor(plugin_root, home=home,
                           settings_path=(state_root or home / "engram/learner") / "settings.json")
        if chosen is None:
            return
        target, pins = chosen
        entry = target / "scripts" / script_name
        require(script_name in {"engram_hook.py", "codex_learner.py"} and entry in pins,
                "routing_entry_missing")
        for path, identity in pins.items():
            require(_identity(path.lstat()) == identity, "routing_path_changed")
        if deadline is not None:
            require(math.isfinite(deadline) and time.monotonic() < deadline, "routing_hook_deadline")
        if target == Path(plugin_root).absolute():
            return
        # A waiting worker must not exec away its CLOEXEC retry ownership and
        # silently restart a fresh waiting budget in another package.
        require(allow_handoff, "routing_selection_changed")
        require(HOP not in os.environ, "routing_hop_limit")
        env = dict(os.environ, CLAUDE_PLUGIN_ROOT=str(target))
        env[HOP] = "1"  # A second handoff refuses; it never authorizes a target.
        if deadline is not None:
            env[HOOK_DEADLINE] = repr(deadline)
        os.execve(sys.executable, [sys.executable, "-B", str(entry), *argv], env)
    except Refused:
        raise
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        raise Refused("routing_unavailable") from None
