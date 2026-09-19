"""Python-only process test: inherited flock survives abrupt worker exit.

The worker exercises the real provider_slot and run_codex Popen composition, but
substitutes a fixed Python dummy child for Codex. No native Engram, Codex provider,
network, database, or memory transport is invoked.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT

SOURCE = PLUGIN_ROOT / "scripts"


class LockInheritanceTests(unittest.TestCase):
    def test_abrupt_worker_exit_keeps_provider_slot_until_dummy_child_exits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            codex = root / 'codex'; codex.mkdir(mode=0o700)
            (codex / 'config.toml').write_text('[mcp_servers.memory]\ncommand="/not-executed/memory"\ndefault_tools_approval_mode="approve"\n')
            run = root / 'run'; run.mkdir(mode=0o700)
            ready = root / 'child-ready.json'
            release = root / 'release-child'
            dummy = root / 'dummy.py'
            dummy.write_text('''import json, os, pathlib, sys, time
fd, ready, release = int(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
os.fstat(fd)
ready.write_text(json.dumps({"pid": os.getpid(), "fd": fd}))
deadline=time.monotonic()+15
while not release.exists() and time.monotonic()<deadline:
    time.sleep(0.01)
''')
            worker = root / 'worker.py'
            worker.write_text('''import os, pathlib, subprocess, sys, time, types
sys.path.insert(0, sys.argv[1])
from codex_learner import runner
root=pathlib.Path(sys.argv[2]); actual_popen=subprocess.Popen
# Keep the production descriptor, cwd, stdio, and environment arguments. Only
# replace the unexecuted Codex argv with a fixed local Python dummy program.
def dummy_provider(argv, **kwargs):
    fds=kwargs.get("pass_fds", ())
    if len(fds)!=1 or fds[0]!=runner._PROVIDER_LOCK_FD.get():
        raise AssertionError("provider did not inherit the internal slot descriptor")
    child=actual_popen([sys.executable, str(root/"dummy.py"), str(fds[0]), str(root/"child-ready.json"), str(root/"release-child")], **kwargs)
    deadline=time.monotonic()+5
    while not (root/"child-ready.json").exists() and time.monotonic()<deadline:
        time.sleep(.01)
    if not (root/"child-ready.json").exists():
        child.terminate(); child.wait(); raise AssertionError("dummy child never became ready")
    os._exit(0) # Bypass finally/context cleanup just like uncatchable worker death.
runner.subprocess.Popen=dummy_provider
config={**runner.DEFAULTS, "codex_bin":"/not-executed/codex"}
with runner.provider_slot():
    runner.run_codex(root, root/"run", {"session_id":"synthetic", "cwd":str(root), "event":"Stop"}, types.SimpleNamespace(text="Synthetic visible excerpt",next_offset=42), config)
''')
            env = dict(os.environ, CODEX_HOME=str(codex), PYTHONDONTWRITEBYTECODE='1')
            worker_proc = subprocess.Popen([sys.executable, '-B', str(worker), str(SOURCE), str(root)],
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            lock = None
            try:
                stdout, stderr = worker_proc.communicate(timeout=8)
                self.assertEqual(worker_proc.returncode, 0, stderr.decode())
                self.assertTrue(ready.is_file())
                lock = (codex / 'engram/learner-provider.lock').open('a+')
                # The worker has exited; only the dummy provider holds its
                # inherited open-file description. A new worker still loses.
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                release.touch()
                deadline = time.monotonic() + 5
                acquired = False
                while time.monotonic() < deadline:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        acquired = True
                        break
                    except BlockingIOError:
                        time.sleep(0.01)
                self.assertTrue(acquired, 'slot remained locked after dummy child exit')
            finally:
                release.touch(exist_ok=True)
                if worker_proc.poll() is None:
                    worker_proc.terminate(); worker_proc.wait(timeout=2)
                if lock is not None:
                    lock.close()


if __name__ == '__main__':
    unittest.main()
