"""Persistent identity ABI and race tests; only owned files and fake syscalls.

No native library, provider, database, subprocess or network is used. A separate
read-only qualification receipt binds actual Darwin behavior to a source hash.
"""
import ctypes
import dataclasses
import importlib.util
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import uuid

from suite_support import PLUGIN_ROOT, TEMP_ROOT


SOURCE = PLUGIN_ROOT / "scripts/codex_learner/file_identity.py"
SPEC = importlib.util.spec_from_file_location("_file_identity_under_test", SOURCE)
IDENTITY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = IDENTITY
SPEC.loader.exec_module(IDENTITY)
UUID = "e535dd8a-5390-470f-b07b-bb0c5dd6414b"
OTHER_UUID = "d535dd8a-5390-470f-b07b-bb0c5dd6414b"


def attributes(*, length=72, common=0x80000000, volume=0x60000,
               capabilities=0x20001, valid=0x20001, volume_uuid=UUID):
    return struct.pack("=14I16s", length, common, volume, 0, 0, 0,
                       capabilities, 0, 0, 0, valid, 0, 0, 0,
                       uuid.UUID(volume_uuid).bytes)


class ValidationTests(unittest.TestCase):
    def test_returns_same_validated_dict_and_supports_full_inode_width(self):
        value = {"scheme": IDENTITY.SCHEME, "volume_uuid": UUID,
                 "inode": (1 << 64) - 1}
        self.assertIs(IDENTITY.validate(value), value)

    def test_rejects_nonexact_shape_and_scheme(self):
        valid = {"scheme": IDENTITY.SCHEME, "volume_uuid": UUID, "inode": 12}
        for value in [None, [], {}, {**valid, "device": 42},
                      {**valid, "scheme": "device_inode_v1"}]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "admission_identity_"):
                IDENTITY.validate(value)

    def test_rejects_noncanonical_and_zero_uuids(self):
        for value in [None, 4, UUID.upper(), UUID.replace("-", ""), "{" + UUID + "}",
                      "0" * 36, "00000000-0000-0000-0000-000000000000"]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "uuid_invalid"):
                IDENTITY.validate({"scheme": IDENTITY.SCHEME, "volume_uuid": value, "inode": 12})

    def test_rejects_noninteger_and_out_of_range_inodes(self):
        for value in [False, True, 0, -1, 1 << 64, 3.0, "3", None]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "inode_invalid"):
                IDENTITY.validate({"scheme": IDENTITY.SCHEME, "volume_uuid": UUID, "inode": value})


class AttributeTests(unittest.TestCase):
    def test_accepts_fixed_sdk_layout(self):
        self.assertEqual(IDENTITY._parse_volume(attributes()), UUID)

    def test_rejects_truncation_and_reported_overflow(self):
        raw = attributes()
        for value in [raw[:-1], raw + b"\0", attributes(length=71), attributes(length=73)]:
            with self.subTest(length=len(value)), self.assertRaisesRegex(ValueError, "attributes_malformed"):
                IDENTITY._parse_volume(value)

    def test_rejects_missing_or_unrequested_returned_masks(self):
        for options in [{"common": 0}, {"common": 0x80000001}, {"volume": 0x20000},
                        {"volume": 0x40000}, {"volume": 0x80060000}, {"volume": 0x60001}]:
            with self.subTest(options=options), self.assertRaisesRegex(ValueError, "attributes_unsupported"):
                IDENTITY._parse_volume(attributes(**options))

    def test_rejects_invalid_or_missing_persistence_capabilities(self):
        for field in ("capabilities", "valid"):
            for value in (0, 1, 0x20000):
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "persistence_unsupported"):
                    IDENTITY._parse_volume(attributes(**{field: value}))

    def test_accepts_additional_declared_capabilities(self):
        self.assertEqual(IDENTITY._parse_volume(attributes(capabilities=0x20003,
                                                         valid=0xFFFFFFFF)), UUID)

    def test_rejects_zero_uuid_even_when_returned_mask_claims_support(self):
        with self.assertRaisesRegex(ValueError, "uuid_invalid"):
            IDENTITY._parse_volume(attributes(volume_uuid="00000000-0000-0000-0000-000000000000"))


class Function:
    def __init__(self, call=lambda *args: 0):
        self.call = call
        self.argtypes = self.restype = None

    def __call__(self, *args):
        return self.call(*args)


class NativeBoundaryTests(unittest.TestCase):
    def test_sdk_layout_and_architecture_specific_symbol(self):
        self.assertEqual(ctypes.sizeof(IDENTITY._StatFS64), 2168)
        self.assertEqual(IDENTITY._StatFS64.f_fsid.offset, 48)
        self.assertEqual(IDENTITY._StatFS64.f_mntonname.offset, 88)
        self.assertEqual(ctypes.sizeof(IDENTITY._AttrList), 24)
        for architecture, symbol in [("arm64", "fstatfs"), ("x86_64", "fstatfs$INODE64")]:
            library = type("Library", (), {})()
            function = Function()
            setattr(library, symbol, function)
            library.fgetattrlist = Function()
            with self.subTest(architecture=architecture), mock.patch.object(IDENTITY.sys, "platform", "darwin"), \
                    mock.patch.object(IDENTITY.platform, "machine", return_value=architecture), \
                    mock.patch.object(IDENTITY.ctypes, "CDLL", return_value=library):
                native = IDENTITY._Darwin()
                self.assertIs(native.statfs, function)
                self.assertIs(native.getattr.argtypes[-1], ctypes.c_uint)

    def test_unsupported_platform_never_loads_native_library(self):
        with mock.patch.object(IDENTITY.sys, "platform", "linux"), \
                mock.patch.object(IDENTITY.ctypes, "CDLL") as load:
            with self.assertRaisesRegex(ValueError, "platform_unsupported"):
                IDENTITY._Darwin()
            load.assert_not_called()

    def test_missing_native_symbol_is_bounded_failure(self):
        with mock.patch.object(IDENTITY.sys, "platform", "darwin"), \
                mock.patch.object(IDENTITY.platform, "machine", return_value="arm64"), \
                mock.patch.object(IDENTITY.ctypes, "CDLL", return_value=object()):
            with self.assertRaisesRegex(ValueError, "api_unavailable"):
                IDENTITY._Darwin()

    def test_getattr_request_and_fixed_buffer(self):
        native = IDENTITY._Darwin.__new__(IDENTITY._Darwin)
        calls = []

        def getattr_call(fd, pointer, buffer, size, options):
            request = ctypes.cast(pointer, ctypes.POINTER(IDENTITY._AttrList)).contents
            calls.append((fd, request.bitmapcount, request.reserved, request.commonattr,
                          request.volattr, request.dirattr, request.fileattr,
                          request.forkattr, size, options))
            ctypes.memmove(buffer, attributes(), size)
            return 0

        native.getattr = getattr_call
        self.assertEqual(native.volume_uuid(17), UUID)
        self.assertEqual(calls, [(17, 5, 0, 0x80000000, 0x80060000, 0, 0, 0, 72, 12)])

    def test_getattr_syscall_failure_is_bounded(self):
        native = IDENTITY._Darwin.__new__(IDENTITY._Darwin)
        native.getattr = lambda *args: -1
        with self.assertRaisesRegex(ValueError, "attributes_unavailable"):
            native.volume_uuid(17)

    def native_filesystem(self, *, kind=b"apfs", flags=0x1000, mount=b"/Volumes/test", result=0):
        native = IDENTITY._Darwin.__new__(IDENTITY._Darwin)

        def statfs_call(fd, pointer):
            value = ctypes.cast(pointer, ctypes.POINTER(IDENTITY._StatFS64)).contents
            value.f_fsid[:] = (42, 26)
            value.f_type = 26
            value.f_flags = flags
            value.f_fstypename = kind
            value.f_mntonname = mount
            value.f_mntfromname = b"/dev/test"
            return result

        native.statfs = statfs_call
        return native

    def test_statfs_parsing_and_local_apfs_requirement(self):
        fs = self.native_filesystem().filesystem(17)
        self.assertEqual(fs.fsid, (42, 26))
        self.assertEqual(fs.mount, "/Volumes/test")
        for options in [{"kind": b"hfs"}, {"kind": b"nfs"}, {"flags": 0}]:
            with self.subTest(options=options), self.assertRaisesRegex(ValueError, "filesystem_unsupported"):
                self.native_filesystem(**options).filesystem(17)

    def test_statfs_malformed_mount_and_unterminated_string(self):
        for mount in [b"", b"relative", b"/Volumes/../test", b"x" * 1024]:
            with self.subTest(mount=mount[:20]), self.assertRaisesRegex(ValueError, "(mount_invalid|filesystem_malformed)"):
                self.native_filesystem(mount=mount).filesystem(17)

    def test_statfs_syscall_failure_is_bounded(self):
        with self.assertRaisesRegex(ValueError, "filesystem_unavailable"):
            self.native_filesystem(result=-1).filesystem(17)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEMP_ROOT, prefix="identity-")
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / "mount"
        self.root.mkdir()
        self.file = self.root / "target"
        self.file.write_bytes(b"owned fixture\n")
        self.fd = os.open(self.file, os.O_RDONLY)
        self.addCleanup(os.close, self.fd)
        self.fs = IDENTITY._Filesystem((42, 26), 26, 1, 0x1000, b"apfs", str(self.root), b"/dev/test")
        self.backend = mock.Mock()
        self.backend.filesystem.return_value = self.fs
        self.backend.volume_uuid.return_value = UUID
        patch = mock.patch.object(IDENTITY, "_Darwin", return_value=self.backend)
        patch.start()
        self.addCleanup(patch.stop)

    def assert_owned_fds_closed(self):
        fds = {args[0] for args, _ in self.backend.filesystem.call_args_list}
        for fd in fds:
            self.assertNotEqual(fd, self.fd)
            with self.assertRaises(OSError):
                os.fstat(fd)
        os.fstat(self.fd)

    def test_capture_retains_caller_and_uses_volume_root_without_seeking(self):
        os.lseek(self.fd, 2, os.SEEK_SET)
        result = IDENTITY.capture_fd(self.fd)
        self.assertEqual(result, {"scheme": IDENTITY.SCHEME, "volume_uuid": UUID,
                                  "inode": self.file.stat().st_ino})
        self.assertEqual(os.lseek(self.fd, 0, os.SEEK_CUR), 2)
        root_fds = [args[0] for args, _ in self.backend.volume_uuid.call_args_list]
        self.assertEqual(len(root_fds), 2)
        self.assertEqual(root_fds[0], root_fds[1])
        self.assertEqual(self.backend.filesystem.call_count, 4)
        self.assert_owned_fds_closed()

    def test_directory_target_supported(self):
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            self.assertEqual(IDENTITY.capture_fd(fd)["inode"], self.root.stat().st_ino)
        finally:
            os.close(fd)

    def test_invalid_fd_values_and_closed_fd(self):
        for fd in [True, None, -1, 1 << 31]:
            with self.subTest(fd=fd), self.assertRaisesRegex(ValueError, "fd_invalid"):
                IDENTITY.capture_fd(fd)
        closed = os.dup(self.fd)
        os.close(closed)
        with self.assertRaisesRegex(ValueError, "identity_unavailable"):
            IDENTITY.capture_fd(closed)

    def test_fifo_target_rejected(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        try:
            with self.assertRaisesRegex(ValueError, "file_type_unsupported"):
                IDENTITY.capture_fd(fd)
        finally:
            os.close(fd)

    def test_root_filesystem_mismatch(self):
        self.backend.filesystem.side_effect = [self.fs, dataclasses.replace(self.fs, fsid=(43, 26))]
        with self.assertRaisesRegex(ValueError, "root_mismatch"):
            IDENTITY.capture_fd(self.fd)
        self.backend.volume_uuid.assert_not_called()
        self.assert_owned_fds_closed()

    def test_root_current_device_mismatch(self):
        real_fstat = os.fstat
        root_inode = self.root.stat().st_ino

        def changed_device(fd):
            result = real_fstat(fd)
            if result.st_ino == root_inode:
                fields = list(result)
                fields[2] += 1
                return os.stat_result(fields)
            return result

        with mock.patch.object(IDENTITY.os, "fstat", side_effect=changed_device):
            with self.assertRaisesRegex(ValueError, "root_mismatch"):
                IDENTITY.capture_fd(self.fd)
        self.backend.volume_uuid.assert_not_called()
        self.assert_owned_fds_closed()

    def test_mount_symlink_rejected_before_query(self):
        alias = self.parent / "alias"
        alias.symlink_to(self.root)
        self.backend.filesystem.return_value = dataclasses.replace(self.fs, mount=str(alias))
        with self.assertRaisesRegex(ValueError, "mount_invalid"):
            IDENTITY.capture_fd(self.fd)
        self.backend.volume_uuid.assert_not_called()
        self.assert_owned_fds_closed()

    def test_root_path_replacement_detected(self):
        def replace_root(fd):
            if self.root.exists():
                self.root.rename(self.parent / "moved")
                self.root.mkdir()
            return UUID

        # Replace only once; the second volume query must still return UUID.
        def once(fd):
            self.backend.volume_uuid.side_effect = None
            self.backend.volume_uuid.return_value = UUID
            return replace_root(fd)
        self.backend.volume_uuid.side_effect = once
        with self.assertRaisesRegex(ValueError, "root_changed"):
            IDENTITY.capture_fd(self.fd)
        self.assert_owned_fds_closed()

    def test_target_permissions_changed_during_observation(self):
        def chmod_target(fd):
            self.file.chmod(0o600)
            return UUID

        self.file.chmod(0o640)
        self.backend.volume_uuid.side_effect = chmod_target
        with self.assertRaisesRegex(ValueError, "target_changed"):
            IDENTITY.capture_fd(self.fd)
        self.assert_owned_fds_closed()

    def test_target_fd_replacement_detected_while_retained_fd_remains_original(self):
        other = self.root / "other"
        other.write_bytes(b"different")

        def replace_target(fd):
            with other.open("rb") as stream:
                os.dup2(stream.fileno(), self.fd)
            return UUID

        self.backend.volume_uuid.side_effect = replace_target
        with self.assertRaisesRegex(ValueError, "target_changed"):
            IDENTITY.capture_fd(self.fd)
        self.assert_owned_fds_closed()

    def test_volume_uuid_drift_detected(self):
        self.backend.volume_uuid.side_effect = [UUID, OTHER_UUID]
        with self.assertRaisesRegex(ValueError, "volume_changed"):
            IDENTITY.capture_fd(self.fd)
        self.assert_owned_fds_closed()

    def test_filesystem_drift_detected_after_uuid_query(self):
        self.backend.filesystem.side_effect = [self.fs, self.fs,
                                               dataclasses.replace(self.fs, source=b"/dev/other")]
        with self.assertRaisesRegex(ValueError, "filesystem_changed"):
            IDENTITY.capture_fd(self.fd)
        self.assert_owned_fds_closed()

    def test_metadata_syscall_error_closes_owned_fds(self):
        self.backend.volume_uuid.side_effect = OSError("fixture failure")
        with self.assertRaisesRegex(ValueError, "identity_unavailable"):
            IDENTITY.capture_fd(self.fd)
        self.assert_owned_fds_closed()

    def test_append_during_observation_does_not_change_identity(self):
        def append(fd):
            with self.file.open("ab") as stream:
                stream.write(b"new transcript event\n")
            return UUID

        self.backend.volume_uuid.side_effect = append
        self.assertEqual(IDENTITY.capture_fd(self.fd)["inode"], os.fstat(self.fd).st_ino)

    def test_device_renumber_between_operations_is_not_durable(self):
        before = IDENTITY.capture_fd(self.fd)
        fstat, lstat = os.fstat, os.lstat

        def renumber(value):
            fields = list(value)
            fields[2] += 500
            return os.stat_result(fields)

        with mock.patch.object(IDENTITY.os, "fstat", side_effect=lambda fd: renumber(fstat(fd))), \
                mock.patch.object(IDENTITY.os, "lstat", side_effect=lambda *a, **k: renumber(lstat(*a, **k))):
            after = IDENTITY.capture_fd(self.fd)
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
