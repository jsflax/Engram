#!/usr/bin/env python3
"""Independent format-v1 fixture; stdlib only, no production encoder import."""
import hashlib
import struct


def u64(value):
    return struct.pack(">Q", value)


def i64(value):
    return struct.pack(">q", value)


def string(value):
    raw = value.encode("utf-8")
    return u64(len(raw)) + raw


def reference_digest():
    # Every field is spelled out in documented order. Membership/scope values
    # are already in canonical order; their input permutations are tested in Swift.
    encoded = b"".join([
        string("engram.memory-operation"), u64(1), u64(1),
        string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        u64(1), string("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
        b"\x01", string("cccccccc-cccc-cccc-cccc-cccccccccccc"), string("agent"),
        u64(2), string("11111111-1111-1111-1111-111111111111"),
        string("22222222-2222-2222-2222-222222222222"),
        u64(2), string("agent"), string("full"),
        string("codex"), string("session-1"), string("run-1"),
        u64(17), u64(91), string("a" * 64),
        string("remember"), string("Private fixture: cafe\u0301\nline\x00tail"),
        string("general"), string("global"), string(""), i64(0), b"\x00",
        b"\x00", string("permanent"),
    ])
    return hashlib.sha256(encoded).hexdigest()


if __name__ == "__main__":
    print(reference_digest())
