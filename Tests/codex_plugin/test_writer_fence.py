"""Isolated lock files and real subprocesses; no provider or native store."""
import copy
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
F = importlib.import_module("codex_learner.writer_fence")


def authorized(_binding, _phase):
    return True


class WriterFenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="writer-fence-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.epoch = "11111111-2222-4333-8444-555555555555"
        self.owner = "21111111-2222-4333-8444-555555555555"
        self.binding = F.create(self.root, generation_id=self.epoch, owner_id=self.owner)
        self.raw = (self.root / F.LOCK_NAME).read_bytes()
        self.identity = (self.root / F.LOCK_NAME).stat().st_ino

    def revoke(self, **kwargs):
        return F.revoke(self.root, self.binding, **{"validate": authorized, **kwargs})

    def child(self, code, *args, pass_fds=()):
        process = subprocess.Popen([sys.executable, "-B", "-c", code, str(PLUGIN_ROOT / "scripts"),
                                    str(self.root), json.dumps(self.binding), *args],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE, pass_fds=pass_fds, start_new_session=True)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stderr.close()
        self.addCleanup(cleanup)
        return process

    def wait_file(self, path, timeout=5):
        deadline = time.monotonic() + timeout
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, str(path))
            time.sleep(0.01)

    def test_shared_handles_are_checked_close_only_and_inode_is_immutable(self):
        first = F.acquire_shared(self.root, self.binding)
        second = F.acquire_shared(self.root, self.binding)
        self.assertEqual(first.mode, "shared")
        self.assertIs(first.verify(self.binding), True)
        fd = first.pass_fds()[0]
        self.assertEqual(os.fstat(fd).st_ino, self.identity)
        first.close()
        with self.assertRaisesRegex(ValueError, "closed"):
            first.verify(self.binding)
        with self.assertRaisesRegex(ValueError, "busy"):
            self.revoke(timeout_seconds=0)
        second.close()
        with self.revoke() as recovery:
            self.assertEqual(recovery.mode, "exclusive")
            self.assertIs(recovery.verify(self.binding), True)
            with self.assertRaisesRegex(ValueError, "recovery_descriptor_not_writable"):
                recovery.pass_fds()
        self.assertEqual((self.root / F.LOCK_NAME).read_bytes(), self.raw)
        self.assertEqual((self.root / F.LOCK_NAME).stat().st_ino, self.identity)
        with self.assertRaisesRegex(ValueError, "generation_revoked"):
            F.acquire_shared(self.root, self.binding)
        with self.assertRaisesRegex(ValueError, "generation_revoked"):
            F.create(self.root, generation_id=self.epoch, owner_id=self.owner)

    def test_creation_never_adopts_existing_inode(self):
        with self.assertRaisesRegex(ValueError, "lock_already_exists"):
            F.create(self.root, generation_id=self.epoch, owner_id=self.owner)
        self.assertEqual((self.root / F.LOCK_NAME).stat().st_ino, self.identity)

    def test_exclusive_recovery_is_idempotent_and_validates_exact_revocation(self):
        with self.revoke() as held:
            receipt = self.root / F.REVOCATION_NAME
            raw = receipt.read_bytes()
            inode = receipt.stat().st_ino
            changed = copy.deepcopy(self.binding)
            changed["owner_id"] = self.epoch
            with self.assertRaises(ValueError):
                held.verify(changed)
        with self.revoke() as held:
            self.assertEqual(receipt.read_bytes(), raw)
            self.assertEqual(receipt.stat().st_ino, inode)
            replacement = self.root / "replacement"
            F.durable._new(replacement, raw)
            os.replace(replacement, receipt)
            with self.assertRaisesRegex(ValueError, "revocation_changed"):
                held.verify(self.binding)

    def test_validators_require_exact_true_at_every_recovery_boundary(self):
        for phase in ("before_acquire", "after_acquire", "before_revocation", "after_revocation"):
            for refused in (False, None, 1):
                with self.subTest(phase=phase, refused=refused):
                    self.setUp()
                    def validate(binding, current):
                        self.assertEqual(binding, self.binding)
                        binding["epoch_id"] = "do-not-mutate-held-binding"
                        return refused if current == phase else True
                    with self.assertRaisesRegex(ValueError, "validation_refused"):
                        self.revoke(validate=validate)
                    self.assertEqual((self.root / F.REVOCATION_NAME).exists(), phase == "after_revocation")
                    if phase != "after_revocation":
                        with F.acquire_shared(self.root, self.binding):
                            pass
        with self.assertRaisesRegex(ValueError, "validator_required"):
            self.revoke(validate=None)

    def test_current_validator_is_rechecked_after_waiting_for_old_writer(self):
        code = r'''
import json,pathlib,sys,time
sys.path.insert(0,sys.argv[1]);from codex_learner import writer_fence as F
root=pathlib.Path(sys.argv[2]);binding=json.loads(sys.argv[3])
with F.acquire_shared(root,binding):
    (root/'ready').write_text('ready')
    time.sleep(.2)
    (root/'policy.changed').write_text('changed')
'''
        child = self.child(code)
        self.wait_file(self.root / "ready")
        phases = []
        def current(binding, phase):
            phases.append(phase)
            return not (self.root / "policy.changed").exists()
        with self.assertRaisesRegex(ValueError, "validation_refused"):
            self.revoke(validate=current, timeout_seconds=2)
        self.assertEqual(child.wait(timeout=5), 0, child.stderr.read().decode())
        self.assertEqual(phases, ["before_acquire", "after_acquire"])
        self.assertFalse((self.root / F.REVOCATION_NAME).exists())

    def test_busy_recovery_is_finite_and_never_publishes_revocation(self):
        with F.acquire_shared(self.root, self.binding):
            start = time.monotonic()
            with self.assertRaisesRegex(ValueError, "busy"):
                self.revoke(timeout_seconds=.1)
            self.assertGreaterEqual(time.monotonic() - start, .09)
            self.assertLess(time.monotonic() - start, 1)
            self.assertFalse((self.root / F.REVOCATION_NAME).exists())
        for invalid in (-1, 6, float("inf"), float("nan"), True, "2"):
            with self.assertRaisesRegex(ValueError, "invalid_timeout"):
                F.acquire_shared(self.root, self.binding, timeout_seconds=invalid)

    def test_missing_replaced_linked_or_changed_lock_cannot_fence_another_inode(self):
        for fault in ("missing", "replace", "symlink", "hardlink", "mode", "bytes"):
            with self.subTest(fault=fault):
                self.setUp()
                held = F.acquire_shared(self.root, self.binding)
                self.addCleanup(held.close)
                lock = self.root / F.LOCK_NAME
                old = self.root / "retained-old"
                if fault in ("missing", "replace", "symlink"):
                    lock.rename(old)
                    if fault == "replace": F.durable._new(lock, self.raw)
                    elif fault == "symlink": lock.symlink_to(old)
                elif fault == "hardlink": os.link(lock, old)
                elif fault == "mode": lock.chmod(0o644)
                else: lock.write_bytes(b"changed")
                with self.assertRaises((ValueError, OSError)):
                    held.verify(self.binding)
                with self.assertRaises((ValueError, OSError)):
                    self.revoke(timeout_seconds=0)
                self.assertFalse((self.root / F.REVOCATION_NAME).exists())

    def test_malformed_or_foreign_revocation_always_blocks_new_writers(self):
        for raw in (b"", b"{", b"{}", b'{"status":"revoked","status":"revoked"}'):
            with self.subTest(raw=raw):
                self.setUp()
                F.durable._new(self.root / F.REVOCATION_NAME, raw)
                with self.assertRaisesRegex(ValueError, "generation_revoked"):
                    F.acquire_shared(self.root, self.binding)
                with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
                    self.revoke()
                self.assertEqual((self.root / F.REVOCATION_NAME).read_bytes(), raw)

    def test_post_acquire_revocation_check_closes_delayed_proxy_race(self):
        code = r'''
import json,pathlib,sys
sys.path.insert(0,sys.argv[1]);from codex_learner import writer_fence as F
root=pathlib.Path(sys.argv[2]);binding=json.loads(sys.argv[3]);(root/'started').write_text('started')
try:F.acquire_shared(root,binding,timeout_seconds=2)
except ValueError as error:
    assert str(error)=='writer_fence_generation_revoked';(root/'refused').write_text('refused')
else:raise AssertionError('old generation became a writer')
'''
        held = self.revoke()
        child = self.child(code)
        self.wait_file(self.root / "started")
        self.assertIsNone(child.poll())
        held.close()
        self.assertEqual(child.wait(timeout=5), 0, child.stderr.read().decode())
        self.assertTrue((self.root / "refused").exists())

    def test_shared_descriptor_survives_parent_close_and_child_blocks_recovery(self):
        code = r'''
import os,pathlib,sys,time
root=pathlib.Path(sys.argv[2]);fd=int(sys.argv[4]);os.fstat(fd);(root/'ready').write_text('ready')
deadline=time.monotonic()+5
while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.01)
os.close(fd)
'''
        held = F.acquire_shared(self.root, self.binding)
        fds = held.pass_fds()
        child = self.child(code, str(fds[0]), pass_fds=fds)
        self.wait_file(self.root / "ready")
        held.close()
        with self.assertRaisesRegex(ValueError, "busy"):
            self.revoke(timeout_seconds=.05)
        (self.root / "release").write_text("release fixture")
        self.assertEqual(child.wait(timeout=5), 0, child.stderr.read().decode())
        with self.revoke():
            pass

    def test_actual_proxy_sigkill_preserves_native_like_child_fence(self):
        code = r'''
import json,os,pathlib,subprocess,sys,time
sys.path.insert(0,sys.argv[1]);from codex_learner import writer_fence as F
root=pathlib.Path(sys.argv[2]);binding=json.loads(sys.argv[3]);held=F.acquire_shared(root,binding);fd=held.pass_fds()[0]
child_code="""
import os,pathlib,sys,time
root=pathlib.Path(sys.argv[1]);fd=int(sys.argv[2]);os.fstat(fd);(root/'child.ready').write_text('ready')
deadline=time.monotonic()+5
while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.01)
os.close(fd);(root/'child.done').write_text('closed')
"""
child=subprocess.Popen([sys.executable,'-B','-c',child_code,str(root),str(fd)],pass_fds=(fd,),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
while True:time.sleep(.1)
'''
        proxy = self.child(code)
        try:
            self.wait_file(self.root / "child.ready")
            proxy.kill()
            self.assertEqual(proxy.wait(timeout=5), -signal.SIGKILL)
            with self.assertRaisesRegex(ValueError, "busy"):
                self.revoke(timeout_seconds=.05)
        finally:
            (self.root / "release").write_text("release fixture child")
            if (self.root / "child.ready").exists():
                self.wait_file(self.root / "child.done", timeout=6)
        with self.revoke():
            pass

    def test_real_sigkill_at_revocation_boundaries_never_resurrects_generation(self):
        code = r'''
import json,os,pathlib,signal,sys
sys.path.insert(0,sys.argv[1]);from codex_learner import writer_fence as F
root=pathlib.Path(sys.argv[2]);binding=json.loads(sys.argv[3])
def boundary(label):
    if label==sys.argv[4]:os.kill(os.getpid(),signal.SIGKILL)
F._boundary=boundary
F.revoke(root,binding,validate=lambda _binding,_phase:True)
'''
        for boundary in ("exclusive_acquired", "revocation_created", "revocation_written",
                         "revocation_file_fsynced", "revocation_directory_fsynced"):
            with self.subTest(boundary=boundary):
                self.setUp()
                child = self.child(code, boundary)
                self.assertEqual(child.wait(timeout=5), -signal.SIGKILL, child.stderr.read().decode())
                if boundary == "exclusive_acquired":
                    with F.acquire_shared(self.root, self.binding):
                        pass
                    with self.revoke():
                        pass
                else:
                    with self.assertRaisesRegex(ValueError, "generation_revoked"):
                        F.acquire_shared(self.root, self.binding)
                    if boundary == "revocation_created":
                        with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
                            self.revoke()
                    else:
                        with self.revoke() as recovery:
                            self.assertIs(recovery.verify(self.binding), True)
                self.assertEqual((self.root / F.LOCK_NAME).stat().st_ino, self.identity)

    def test_interrupted_creation_never_adopts_partial_lock(self):
        for boundary in ("lock_created", "lock_written", "lock_file_fsynced", "lock_directory_fsynced"):
            with self.subTest(boundary=boundary):
                directory = self.root / boundary
                directory.mkdir(mode=0o700)
                def crash(label):
                    if label == boundary: raise RuntimeError("fixture_interrupted")
                with mock.patch.object(F, "_boundary", side_effect=crash):
                    with self.assertRaisesRegex(RuntimeError, "fixture_interrupted"):
                        F.create(directory, generation_id=self.epoch, owner_id=self.owner)
                inode = (directory / F.LOCK_NAME).stat().st_ino
                with self.assertRaisesRegex(ValueError, "lock_already_exists"):
                    F.create(directory, generation_id=self.epoch, owner_id=self.owner)
                self.assertEqual((directory / F.LOCK_NAME).stat().st_ino, inode)


if __name__ == "__main__":
    unittest.main()
