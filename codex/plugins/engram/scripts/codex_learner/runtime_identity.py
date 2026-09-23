"""Bounded observed package-file identity; not execution/completion attestation."""
import hashlib
import json
import os
from pathlib import Path
import stat

MAX_SOURCE_BYTES = 1024 * 1024
MAX_MANIFEST_BYTES = 65536


def _observed_file(value, limit, *, suffix=None):
    result = {"path": None, "sha256": None, "status": "path_unavailable"}
    try:
        if not isinstance(value, (str, Path)) or not str(value) or len(str(value)) > 4096:
            return result, None
        path = Path(value)
        if not path.is_absolute():
            return result, None
        path = path.resolve()
        result["path"] = str(path)
        if suffix is not None and path.suffix != suffix:
            result["status"] = "source_path_unavailable"
            return result, None
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        with os.fdopen(os.open(path, flags), "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                result["status"] = "not_regular"
                return result, None
            if before.st_size > limit:
                result["status"] = "too_large"
                return result, None
            raw = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
        if len(raw) > limit:
            result["status"] = "too_large"
            return result, None
        attributes = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, key) != getattr(after, key) for key in attributes):
            result["status"] = "changed_during_read"
            return result, None
        try:
            result["sha256"] = hashlib.sha256(raw).hexdigest()
        except Exception:
            result["status"] = "hash_failed"
            return result, None
        result["status"] = "ok"
        return result, raw
    except FileNotFoundError:
        result["status"] = "missing"
    except OSError:
        result["status"] = "unreadable"
    except (ValueError, RuntimeError, TypeError):
        result["status"] = "path_unavailable"
    return result, None


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def capture(router_file, runner_module, admission_module, host_admission_module=None):
    """Observe invocation module paths; never use route/config/environment paths.

    File hashes describe bytes read now at the imported modules' resolved paths.
    They do not prove loaded bytecode equals those bytes under in-place mutation,
    nor that a worker/provider launched or completed. Failures remain metadata.
    """
    identity = {"schema_version": 1, "evidence": "observed_package_files",
                "status": "incomplete", "package": {"path": None, "version": None,
                                                       "status": "path_unavailable"}, "sources": {}}
    try:
        runner_file = getattr(runner_module, "__file__", None)
        admission_file = getattr(admission_module, "__file__", None)
        template = Path(runner_file).with_name("learner_prompt.md") if runner_file else None
        files = {"router": (router_file, ".py"), "runner": (runner_file, ".py"),
                 "template": (template, ".md"), "admission": (admission_file, ".py")}
        if host_admission_module is not None:
            files["host_admission"] = (getattr(host_admission_module, "__file__", None), ".py")
        file_identity_module = getattr(admission_module, "file_identity", None)
        if file_identity_module is not None:
            files["file_identity"] = (getattr(file_identity_module, "__file__", None), ".py")
        for name, (value, suffix) in files.items():
            identity["sources"][name] = _observed_file(value, MAX_SOURCE_BYTES, suffix=suffix)[0]
        router_path = identity["sources"]["router"]["path"]
        if router_path is not None:
            package = Path(router_path).parent.parent
            identity["package"]["path"] = str(package)
            manifest, raw = _observed_file(package / ".codex-plugin/plugin.json", MAX_MANIFEST_BYTES)
            identity["package"]["manifest"] = manifest
            identity["package"]["status"] = manifest["status"]
            if raw is not None:
                try:
                    value = json.loads(raw, object_pairs_hook=_unique_pairs)
                    version = value.get("version") if isinstance(value, dict) else None
                    if not isinstance(version, str) or not 1 <= len(version) <= 128 or "\0" in version:
                        raise ValueError("invalid_version")
                    identity["package"]["version"] = version
                except (ValueError, TypeError, RecursionError):
                    identity["package"]["status"] = "invalid_manifest"
        if identity["package"]["status"] == "ok" and all(
                source["status"] == "ok" for source in identity["sources"].values()):
            identity["status"] = "complete"
    except Exception:
        # Observability must not turn an existing hook decision into a failure.
        identity["status"] = "identity_unavailable"
    return identity
