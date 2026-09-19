#!/usr/bin/env python3
"""Package portable Engram plugin source with the release's signed native MCP.

No installed plugin, home-directory state, or native build is used. All inputs
are validated before output is written. Tar ownership, modes, order and times
are normalized; signatures and resource bytes are preserved unchanged.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import tarfile


SKILLS = {"forget", "hook-status", "maintenance", "memory-status", "recall",
          "remember", "session-learn"}
HOOKS = {"SessionStart", "UserPromptSubmit", "SubagentStart", "PreToolUse",
         "PostToolUse", "Stop", "SubagentStop", "PreCompact", "SessionEnd"}
BUNDLES = ("Engram_EngramKit.bundle", "swift-transformers_Hub.bundle",
           "SwiftLM_SwiftLM.bundle", "swift-crypto_Crypto.bundle")
RESOURCE_FILES = {
    "Engram_EngramKit.bundle": (
        "memory-maintenance.md", "session-learner.md", "sync-reconciliation.md",
        "paraphrase-MiniLM-L6-v2_tokenizer/vocab.txt",
        "paraphrase-MiniLM-L6-v2_tokenizer/tokenizer.json",
        "paraphrase-MiniLM-L6-v2_tokenizer/tokenizer_config.json",
        "paraphrase-MiniLM-L6-v2_tokenizer/special_tokens_map.json",
        "paraphrase-MiniLM-L6-v2_Embedding.mlmodelc/coremldata.bin",
        "paraphrase-MiniLM-L6-v2_Embedding.mlmodelc/model.mil",
        "paraphrase-MiniLM-L6-v2_Embedding.mlmodelc/weights/weight.bin",
        "RecallGateClassifier.mlmodelc/coremldata.bin",
    ),
    "swift-transformers_Hub.bundle": ("t5_tokenizer_config.json", "gpt2_tokenizer_config.json"),
    "SwiftLM_SwiftLM.bundle": ("qwen_tokenizer.json", "qwen_tokenizer_config.json",
                            "llama_tokenizer.json", "llama_tokenizer_config.json"),
    "swift-crypto_Crypto.bundle": ("PrivacyInfo.xcprivacy",),
}
SOURCE_ROOTS = {".codex-plugin", ".mcp.json", "README.md", "LICENSE", "PROVENANCE.json",
                "assets", "hooks", "scripts", "skills"}
RUNTIME_SCRIPTS = (
    "engram-hook", "engram_hook.py", "recall_hook.py", "lifecycle_hook.py",
    "learner_router.py", "codex_learner.py", "codex_learner/__init__.py",
    "codex_learner/admission.py", "codex_learner/host_admission.py",
    "codex_learner/learner_prompt.md", "codex_learner/runner.py",
    "codex_learner/memory_proxy.py", "codex_learner/memory_config.py",
    "codex_learner/runtime_identity.py", "codex_learner/stdio_bridge.py",
    "codex_learner/transcript.py",
)
VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:alpha|beta|rc)\.[1-9]\d*)?")
PRIVATE_PATH = re.compile(r"(?:/Users/|/home/)[^\s\"'<>/]+/|[A-Za-z]:\\{1,2}Users\\{1,2}", re.I)
SECRET = re.compile(
    r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----(?:\s*\n|\\n)"
    r"|\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,})\b"
)
FORBIDDEN_NAMES = {".git", ".env", ".DS_Store", "__pycache__", "auth.json",
                   "credentials.json", "config.toml", "admission.json", "settings.json",
                   "deployment.json", "events.jsonl", "sessions", "transcripts", "state"}
FORBIDDEN_SUFFIXES = {".sqlite", ".sqlite3", ".db", ".jsonl", ".log", ".pyc", ".p12",
                      ".pem", ".key", ".keychain-db"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_name(relative: Path) -> None:
    for part in relative.parts:
        require(part not in FORBIDDEN_NAMES and not part.startswith((".env.", ".engram-native-"))
                and Path(part).suffix.lower() not in FORBIDDEN_SUFFIXES
                and not part.endswith(("-wal", "-shm")),
                f"private/state artifact is not package input: {relative}")


def files_in(root: Path) -> dict[str, Path]:
    require(root.is_dir() and not root.is_symlink(), "input must be a real directory")
    result = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        safe_name(relative)
        mode = path.lstat().st_mode
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), f"links/special files forbidden: {relative}")
        if stat.S_ISREG(mode):
            require(path.stat().st_nlink == 1, f"hard-linked input forbidden: {relative}")
            require(path.stat().st_size > 0 or relative.name == "__init__.py",
                    f"empty package input: {relative}")
            result[relative.as_posix()] = path
    return result


def inspect_source(source: Path, version: str) -> dict[str, Path]:
    files = files_in(source)
    for name, path in files.items():
        relative = Path(name)
        require(relative.parts[0] in SOURCE_ROOTS, f"unexpected plugin source: {name}")
        require(relative.suffix in {".json", ".py", ".md", ".yaml", ".png"}
                or name in {"LICENSE", "scripts/engram-hook"}, f"unexpected source file: {name}")
        if relative.suffix != ".png":
            require(path.stat().st_size <= 2 * 1024 * 1024, f"oversize source text: {name}")
            text = path.read_text(encoding="utf-8")
            require(not PRIVATE_PATH.search(text), f"private absolute path in plugin source: {name}")
            require(not SECRET.search(text), f"credential material in plugin source: {name}")
    required = {".codex-plugin/plugin.json", ".mcp.json", "hooks/hooks.json",
                "assets/engram.png", "README.md", "LICENSE", "PROVENANCE.json",
                "skills/hook-status/scripts/hook_status.py"}
    required.update(f"skills/{name}/SKILL.md" for name in SKILLS)
    required.update(f"skills/{name}/agents/openai.yaml" for name in SKILLS)
    required.update(f"scripts/{name}" for name in RUNTIME_SCRIPTS)
    require(required <= files.keys(), f"missing plugin source: {sorted(required - files.keys())}")
    require(files.keys() <= required, f"unexpected plugin source files: {sorted(files.keys() - required)}")
    skills = {Path(name).parts[1] for name in files if name.startswith("skills/")}
    require(skills == SKILLS, "plugin must contain the seven release skills")
    manifest = json.loads(files[".codex-plugin/plugin.json"].read_text())
    require(manifest.get("name") == "engram" and manifest.get("version") == version,
            "plugin name/version must match the release and cache version")
    require(manifest.get("skills") == "./skills/" and manifest.get("mcpServers") == "./.mcp.json",
            "plugin component references must be relative")
    interface = manifest.get("interface", {})
    require(interface.get("displayName") == "Engram", "plugin display name must be Engram")
    require(all(interface.get(key) == "./assets/engram.png" for key in ("composerIcon", "logo", "logoDark")),
            "plugin must use its bundled Engram icon")
    require(files["assets/engram.png"].read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "invalid app icon")
    mcp = json.loads(files[".mcp.json"].read_text()).get("mcpServers", {})
    require(set(mcp) == {"memory"}, "plugin must declare exactly the memory MCP")
    require(mcp["memory"].get("command") == "./bin/memory"
            and mcp["memory"].get("args") == [] and mcp["memory"].get("cwd") == "."
            and not mcp["memory"].get("env"), "MCP must use the bundled native memory without private overrides")
    hooks = json.loads(files["hooks/hooks.json"].read_text()).get("hooks", {})
    require(set(hooks) == HOOKS, "plugin must contain the nine release hook events")
    for event, groups in hooks.items():
        require(isinstance(groups, list) and len(groups) == 1, f"invalid hook group: {event}")
        commands = groups[0].get("hooks", [])
        require(len(commands) == 1 and commands[0].get("type") == "command"
                and commands[0].get("command") == '/bin/sh "${CLAUDE_PLUGIN_ROOT}/scripts/engram-hook"',
                f"hook must use the portable packaged router: {event}")
    provenance = json.loads(files["PROVENANCE.json"].read_text())
    icon = provenance.get("icon", {})
    require(icon.get("copied_to") == "assets/engram.png"
            and icon.get("sha256") == file_digest(files["assets/engram.png"]),
            "bundled icon must match its retained app-icon provenance")
    return files


def verify_native(binary: Path, expected_team: str) -> None:
    with binary.open("rb") as stream:
        header = stream.read(8)
    require(len(header) == 8 and struct.unpack("<II", header) == (0xFEEDFACF, 0x0100000C),
            "memory must be a thin arm64 Mach-O executable")
    require(bool(binary.stat().st_mode & stat.S_IXUSR), "native memory is not executable")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                   check=True, capture_output=True, text=True)
    identity = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(binary)],
                              check=True, capture_output=True, text=True).stderr
    require("Authority=Developer ID Application:" in identity
            and f"TeamIdentifier={expected_team}" in identity.splitlines(),
            "memory must retain the expected Developer ID signature")


def native_files(cli: Path, expected_team: str) -> dict[str, Path]:
    require(cli.is_dir() and not cli.is_symlink(), "signed CLI input must be a real directory")
    # Only the MCP and resource bundles are package inputs. Other signed CLI
    # products, installer payloads and agents remain outside this plugin.
    for child in cli.iterdir():
        safe_name(Path(child.name))
    binary = cli / "memory"
    require(binary.is_file() and not binary.is_symlink() and binary.stat().st_nlink == 1,
            "signed native memory missing or not a regular unlinked file")
    require({path.name for path in cli.glob("*.bundle")} == set(BUNDLES),
            "signed CLI must contain exactly the four qualified Swift resource bundles")
    result = {"bin/memory": binary}
    for bundle in BUNDLES:
        resources = files_in(cli / bundle)
        require(set(RESOURCE_FILES[bundle]) <= resources.keys(), f"missing runtime resources in {bundle}")
        for relative, path in resources.items():
            require(path.suffix in {".json", ".txt", ".md", ".mil", ".bin", ".xcprivacy", ".plist"}
                    or path.name == "CodeResources", f"unexpected runtime resource: {bundle}/{relative}")
            result[f"bin/{bundle}/{relative}"] = path
    verify_native(binary, expected_team)
    return result


def describe(name: str, value: Path | bytes) -> dict:
    return {"path": name, "bytes": len(value) if isinstance(value, bytes) else value.stat().st_size,
            "sha256": hashlib.sha256(value).hexdigest() if isinstance(value, bytes) else file_digest(value)}


def write_archive(raw, files: dict[str, Path | bytes]) -> None:
    directories = {"engram"}
    for name in files:
        directories.update(parent.as_posix() for parent in (Path("engram") / name).parents if parent != Path("."))
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name in sorted(directories):
                entry = tarfile.TarInfo(name)
                entry.type, entry.mode = tarfile.DIRTYPE, 0o755
                archive.addfile(entry)
            for name, value in sorted(files.items()):
                entry = tarfile.TarInfo("engram/" + name)
                entry.mode = 0o755 if name in {"bin/memory", "scripts/engram-hook"} else 0o644
                entry.size = len(value) if isinstance(value, bytes) else value.stat().st_size
                if isinstance(value, bytes):
                    archive.addfile(entry, io.BytesIO(value))
                else:
                    with value.open("rb") as stream:
                        archive.addfile(entry, stream)


def package(*, source: Path, cli: Path, output: Path, manifest_output: Path,
            version: str, source_sha: str, expected_team: str,
            workflow_run: str | None = None, run_attempt: int = 1) -> dict:
    require(bool(VERSION.fullmatch(version)), "release version must be stable or alpha/beta/rc SemVer")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", source_sha)), "full source SHA required")
    require(bool(re.fullmatch(r"[A-Z0-9]{10}", expected_team)), "expected Apple team ID required")
    require(workflow_run is None or bool(re.fullmatch(r"https://github.com/jsflax/Engram/actions/runs/[0-9]+", workflow_run)),
            "workflow provenance must identify an Engram Actions run")
    require(type(run_attempt) is int and run_attempt > 0, "positive run attempt required")
    require(output.resolve() != manifest_output.resolve(), "archive and manifest outputs must differ")
    for path in (output, manifest_output):
        require(not path.exists() and not path.is_symlink(), "refusing to overwrite package output")
        require(not any(path.resolve().is_relative_to(root.resolve()) for root in (source, cli)),
                "package outputs must be outside input directories")
    files: dict[str, Path | bytes] = inspect_source(source, version)
    files.update(native_files(cli, expected_team))
    provenance = {
        "schemaVersion": 1, "name": "engram", "version": version,
        "source": {"repository": "https://github.com/jsflax/Engram", "commit": source_sha,
                   "pluginPath": "codex/plugins/engram"},
        "native": {**describe("bin/memory", files["bin/memory"]), "architecture": "arm64",
                   "signature": "verified Developer ID Application", "source": "signed app CLI export"},
        "runtimeBundles": list(BUNDLES), "skills": sorted(SKILLS), "hookEvents": sorted(HOOKS),
        "requirements": {"platform": "macOS", "minimumSystemVersion": "15.0", "python": ">=3.11"},
    }
    if workflow_run is not None:
        provenance["workflow"] = {"url": workflow_run, "attempt": run_attempt}
    files["RELEASE-PROVENANCE.json"] = json_bytes(provenance)
    manifest = {**provenance, "files": [describe(name, value) for name, value in sorted(files.items())]}
    for path in (output, manifest_output):
        path.parent.mkdir(parents=True, exist_ok=True)
    created = {}
    try:
        with output.open("xb") as raw:
            identity = os.fstat(raw.fileno())
            created[output] = (identity.st_dev, identity.st_ino)
            write_archive(raw, files)
        manifest["archive"] = {"name": output.name, "bytes": output.stat().st_size, "sha256": file_digest(output)}
        with manifest_output.open("xb") as stream:
            identity = os.fstat(stream.fileno())
            created[manifest_output] = (identity.st_dev, identity.st_ino)
            stream.write(json_bytes(manifest))
    except BaseException:
        # Exclusive-open failure does not grant ownership. A path can also be
        # replaced after we create it; retain that other actor's file as well.
        for path, identity in created.items():
            try:
                current = path.lstat()
                if stat.S_ISREG(current.st_mode) and (current.st_dev, current.st_ino) == identity:
                    path.unlink()
            except OSError:
                pass  # Cleanup must not replace the original packaging error.
        raise
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("plugin-source", "signed-cli-dir", "output", "manifest-output"):
        parser.add_argument("--" + option, type=Path, required=True)
    for option in ("version", "source-sha", "expected-team"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--workflow-run")
    parser.add_argument("--run-attempt", type=int, default=1)
    args = parser.parse_args()
    try:
        result = package(source=args.plugin_source, cli=args.signed_cli_dir, output=args.output,
                         manifest_output=args.manifest_output, version=args.version,
                         source_sha=args.source_sha, expected_team=args.expected_team,
                         workflow_run=args.workflow_run, run_attempt=args.run_attempt)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"Plugin packaging stopped: {exc}\n")
    print(json.dumps(result["archive"], sort_keys=True))


if __name__ == "__main__":
    main()
