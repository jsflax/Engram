"""Descriptor-bound persistent identities for qualified local Darwin volumes.

The ABI below follows Darwin SDK sys/mount.h, sys/attr.h and getattrlist(2).
Volume attributes must be queried on the volume root; ATTR_CMN_FILEID cannot be
combined with that query. Python's 64-bit fstat inode belongs to the retained
target descriptor instead. Device numbers are used only during this observation.

Only local APFS is currently qualified. This is local filesystem provenance,
not authentication against an account owner or a cloned filesystem. Callers
still enforce canonical paths, ownership, metadata and transcript frontier seals.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import os
import platform
import stat
import struct
import sys
import uuid
from typing import Any


SCHEME = "macos_volume_uuid_inode_v1"
_MAX_INODE = (1 << 64) - 1
_MNT_LOCAL = 0x00001000
_RETURNED = 0x80000000
_VOL_INFO = 0x80000000
_VOL_CAPABILITIES = 0x00020000
_VOL_UUID = 0x00040000
_VOLUME_MASK = _VOL_INFO | _VOL_CAPABILITIES | _VOL_UUID
_PERSISTENT_64 = 0x00000001 | 0x00020000
_ATTR_SIZE = 4 + 20 + 32 + 16


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError("admission_identity_" + reason)


def validate(value: Any) -> dict[str, Any]:
    """Validate the exact durable schema; never coerce or repair stored values."""
    _require(type(value) is dict and set(value) == {"scheme", "volume_uuid", "inode"},
             "invalid")
    _require(value["scheme"] == SCHEME, "scheme_unsupported")
    raw = value["volume_uuid"]
    _require(type(raw) is str and len(raw) == 36, "uuid_invalid")
    try:
        parsed = uuid.UUID(raw)
    except (ValueError, AttributeError):
        raise ValueError("admission_identity_uuid_invalid") from None
    _require(parsed.int != 0 and str(parsed) == raw, "uuid_invalid")
    _require(type(value["inode"]) is int and 0 < value["inode"] <= _MAX_INODE,
             "inode_invalid")
    return value


class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_uint16), ("reserved", ctypes.c_uint16),
                ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32),
                ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                ("forkattr", ctypes.c_uint32)]


class _StatFS64(ctypes.Structure):
    # __DARWIN_STRUCT_STATFS64, including the complete 1024-byte mount names.
    _fields_ = [
        ("f_bsize", ctypes.c_uint32), ("f_iosize", ctypes.c_int32),
        ("f_blocks", ctypes.c_uint64), ("f_bfree", ctypes.c_uint64),
        ("f_bavail", ctypes.c_uint64), ("f_files", ctypes.c_uint64),
        ("f_ffree", ctypes.c_uint64), ("f_fsid", ctypes.c_int32 * 2),
        ("f_owner", ctypes.c_uint32), ("f_type", ctypes.c_uint32),
        ("f_flags", ctypes.c_uint32), ("f_fssubtype", ctypes.c_uint32),
        ("f_fstypename", ctypes.c_char * 16),
        ("f_mntonname", ctypes.c_char * 1024),
        ("f_mntfromname", ctypes.c_char * 1024),
        ("f_flags_ext", ctypes.c_uint32), ("f_reserved", ctypes.c_uint32 * 7),
    ]


@dataclass(frozen=True)
class _Filesystem:
    fsid: tuple[int, int]
    kind: int
    subtype: int
    flags: int
    name: bytes
    mount: str
    source: bytes


def _c_string(value: _StatFS64, field: str, length: int) -> bytes:
    raw = ctypes.string_at(ctypes.addressof(value) + getattr(_StatFS64, field).offset,
                           length)
    _require(b"\0" in raw, "filesystem_malformed")
    return raw.split(b"\0", 1)[0]


def _parse_volume(raw: bytes) -> str:
    # getattrlist packs even 64-bit fields on 4-byte boundaries. All selected
    # fields are fixed-size: length, attribute_set_t, capabilities/valid, UUID.
    _require(len(raw) == _ATTR_SIZE, "attributes_malformed")
    fields = struct.unpack("=14I16s", raw)
    _require(fields[0] == _ATTR_SIZE, "attributes_malformed")
    # ATTR_VOL_INFO is a request selector, not a returned attribute.
    _require(fields[1:6] == (_RETURNED, _VOL_CAPABILITIES | _VOL_UUID, 0, 0, 0),
             "attributes_unsupported")
    capabilities, valid = fields[6:10], fields[10:14]
    _require(capabilities[0] & _PERSISTENT_64 == _PERSISTENT_64
             and valid[0] & _PERSISTENT_64 == _PERSISTENT_64,
             "persistence_unsupported")
    identity = str(uuid.UUID(bytes=fields[14]))
    _require(identity != "00000000-0000-0000-0000-000000000000", "uuid_invalid")
    return identity


class _Darwin:
    def __init__(self) -> None:
        machine = platform.machine()
        _require(sys.platform == "darwin" and machine in {"arm64", "x86_64"}
                 and ctypes.sizeof(ctypes.c_void_p) == 8, "platform_unsupported")
        _require(ctypes.sizeof(_StatFS64) == 2168
                 and _StatFS64.f_fsid.offset == 48
                 and _StatFS64.f_mntonname.offset == 88
                 and ctypes.sizeof(_AttrList) == 24, "abi_unsupported")
        try:
            self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            # sys/cdefs.h uses $INODE64 on x86_64, the unsuffixed 64-bit-only
            # entry point on arm64. Never call the legacy x86_64 layout.
            self.statfs = getattr(self.lib, "fstatfs$INODE64" if machine == "x86_64"
                                  else "fstatfs")
            self.statfs.argtypes = [ctypes.c_int, ctypes.POINTER(_StatFS64)]
            self.statfs.restype = ctypes.c_int
            self.getattr = self.lib.fgetattrlist
            self.getattr.argtypes = [ctypes.c_int, ctypes.POINTER(_AttrList),
                                    ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint]
            self.getattr.restype = ctypes.c_int
        except (OSError, AttributeError):
            raise ValueError("admission_identity_api_unavailable") from None

    def filesystem(self, fd: int) -> _Filesystem:
        value = _StatFS64()
        _require(self.statfs(fd, ctypes.byref(value)) == 0, "filesystem_unavailable")
        name = _c_string(value, "f_fstypename", 16)
        _require(name == b"apfs" and value.f_flags & _MNT_LOCAL != 0,
                 "filesystem_unsupported")
        mount = os.fsdecode(_c_string(value, "f_mntonname", 1024))
        _require(bool(mount) and os.path.isabs(mount)
                 and os.path.normpath(mount) == mount, "mount_invalid")
        return _Filesystem(tuple(value.f_fsid), value.f_type, value.f_fssubtype,
                           value.f_flags, name, mount,
                           _c_string(value, "f_mntfromname", 1024))

    def volume_uuid(self, fd: int) -> str:
        request = _AttrList(5, 0, _RETURNED, _VOLUME_MASK, 0, 0, 0)
        buffer = ctypes.create_string_buffer(_ATTR_SIZE)
        # REPORT_FULLSIZE exposes truncation; PACK_INVAL_ATTRS gives a fixed
        # layout whose returned masks must still show every requested value.
        _require(self.getattr(fd, ctypes.byref(request), buffer, _ATTR_SIZE,
                              0x00000004 | 0x00000008) == 0,
                 "attributes_unavailable")
        return _parse_volume(buffer.raw)


def _descriptor_identity(value: os.stat_result) -> tuple[int, ...]:
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink)


def capture_fd(fd: int) -> dict[str, Any]:
    """Capture a stable identity without closing, reading or seeking caller FD.

    There are no retries, subprocesses or persistent caches. Filesystem metadata
    is queried a fixed number of times. Existing hook process deadlines remain
    responsible for bounding a kernel/filesystem stall, as with other fstat calls.
    """
    _require(type(fd) is int and 0 <= fd <= (1 << 31) - 1, "fd_invalid")
    backend = _Darwin()
    retained = root = None
    try:
        initial = os.fstat(fd)
        _require(stat.S_ISREG(initial.st_mode) or stat.S_ISDIR(initial.st_mode),
                 "file_type_unsupported")
        _require(0 < initial.st_ino <= _MAX_INODE and initial.st_nlink > 0,
                 "inode_invalid")
        target = _descriptor_identity(initial)
        retained = os.dup(fd)
        _require(_descriptor_identity(os.fstat(retained)) == target, "target_changed")
        filesystem = backend.filesystem(retained)
        mount = filesystem.mount
        _require(os.path.realpath(mount, strict=True) == mount, "mount_invalid")
        root = os.open(mount, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                       | os.O_CLOEXEC | os.O_NONBLOCK)
        root_info = os.fstat(root)
        _require(stat.S_ISDIR(root_info.st_mode) and root_info.st_dev == initial.st_dev
                 and root_info.st_nlink > 0, "root_mismatch")
        root_identity = _descriptor_identity(root_info)
        _require(_descriptor_identity(os.lstat(mount)) == root_identity,
                 "root_changed")
        _require(backend.filesystem(root) == filesystem, "root_mismatch")
        volume_uuid = backend.volume_uuid(root)
        _require(backend.volume_uuid(root) == volume_uuid, "volume_changed")
        _require(backend.filesystem(retained) == filesystem
                 and backend.filesystem(root) == filesystem, "filesystem_changed")
        _require(_descriptor_identity(os.fstat(retained)) == target
                 and _descriptor_identity(os.fstat(fd)) == target, "target_changed")
        _require(_descriptor_identity(os.fstat(root)) == root_identity
                 and _descriptor_identity(os.lstat(mount)) == root_identity
                 and os.path.realpath(mount, strict=True) == mount, "root_changed")
        return validate({"scheme": SCHEME, "volume_uuid": volume_uuid,
                         "inode": initial.st_ino})
    except OSError:
        raise ValueError("admission_identity_unavailable") from None
    finally:
        if root is not None:
            os.close(root)
        if retained is not None:
            os.close(retained)
