"""Paths shared by the Codex plugin regressions, independent of the caller cwd."""
import atexit
import os
from pathlib import Path
import sys
import tempfile


TEST_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = TEST_ROOT.parents[1]
PLUGIN_ROOT = REPOSITORY_ROOT / "codex/plugins/engram"
if not (PLUGIN_ROOT / ".codex-plugin/plugin.json").is_file():
    raise RuntimeError("Run these tests from a repository containing codex/plugins/engram")

# Default TemporaryDirectory users and the Python-only lock fixture stay inside
# the repository. No test writes into a user's CODEX_HOME, store, or OS temp root.
TEMP_ROOT = TEST_ROOT / ".tmp"
if TEMP_ROOT.is_symlink():
    raise RuntimeError("The fixture directory must not be a symlink")
TEMP_ROOT.mkdir(mode=0o700, exist_ok=True)
tempfile.tempdir = str(TEMP_ROOT)
os.environ["TMPDIR"] = str(TEMP_ROOT)
sys.dont_write_bytecode = True

# Some legacy worker tests exercise the shared provider lock before invoking an
# in-process fake. Give even those default-path accesses an owned empty home.
_session = tempfile.TemporaryDirectory(prefix="suite-home-", dir=TEMP_ROOT)
atexit.register(_session.cleanup)
SESSION_ROOT = Path(_session.name)
TEST_HOME = SESSION_ROOT / "home"
TEST_HOME.mkdir(mode=0o700)
TEST_CODEX_HOME = SESSION_ROOT / "codex"
TEST_CODEX_HOME.mkdir(mode=0o700)
(TEST_CODEX_HOME / "sessions").mkdir(mode=0o700)
(TEST_CODEX_HOME / "config.toml").write_text("")
os.environ["HOME"] = str(TEST_HOME)
os.environ["CODEX_HOME"] = str(TEST_CODEX_HOME)


def fixture_spawn_gate(module, directory):
    """Real kernel admission for unrelated synthetic worker regressions.

    Fixtures have no provider load/cooldown clock: retain actual flock/fsync/FD
    behavior while isolating their state. Dedicated spawn-admission tests use
    the production cooldown and deliberately exercise refusals and crashes.
    A fixed clock also isolates this shared fixture from tests that patch the
    stdlib time module into the future to exercise session retry deadlines.
    """
    from unittest import mock
    production = module.lease
    return mock.patch.object(module, "lease", side_effect=lambda: production(
        directory=directory, now=10_000, load=lambda: 0, cooldown=0))
