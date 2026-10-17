"""Fresh isolated interpreter for actual SIGKILL publication tests on macOS."""
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import sys
from unittest import mock

from legacy_fixture import load_runtime, digest, encode


def main():
    plan_path, boundary = Path(sys.argv[1]), sys.argv[2]
    L = load_runtime()
    plan = json.loads(plan_path.read_bytes())
    paths = L.LegacyPaths(evidence_directory=Path(sys.argv[3]),
                          **{key: Path(value) for key, value in plan["paths"].items()})
    def crash(label):
        if label == boundary:
            os.kill(os.getpid(), signal.SIGKILL)
    L._boundary = L.coordinator._boundary = L.publication._boundary = crash
    original_connect = sqlite3.connect
    def read_only(database, *args, **kwargs):
        assert database == paths.candidate_store.as_uri() + "?mode=ro"
        assert kwargs.get("uri") is True
        return original_connect(database, *args, **kwargs)
    with contextlib.ExitStack() as stack:
        for module, name in ((subprocess, "Popen"), (subprocess, "run"),
                             (subprocess, "call"), (socket, "socket"), (os, "system")):
            stack.enter_context(mock.patch.object(module, name,
                side_effect=AssertionError("provider/native/network forbidden")))
        stack.enter_context(mock.patch.object(sqlite3, "connect", side_effect=read_only))
        L.apply(paths, plan=plan, plan_sha256=digest(encode(plan)))
    raise RuntimeError("requested crash boundary was not reached")


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main()
