"""Internal lifetime guard for one owned provider child (no PID-age recovery).

The runner creates this process as a supervisor. Its provider owns a separate
process group for cancellation. Standard IO, argv, cwd and environment are
inherited unchanged by the provider. Only the
lease stays here: providers may close unknown descriptors. TERM/INT are forwarded
and never release admission until wait() observes the owned child terminate.
"""
from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import time


def run(argv, lease_fd, wall_seconds):
    os.fstat(lease_fd)  # Passed by the admitting runner, never an env override.
    if not argv or not math.isfinite(wall_seconds) or wall_seconds <= 0:
        raise ValueError("invalid_provider_guard_arguments")
    child = None
    requested = None

    def cancelled(signum, _frame):
        nonlocal requested
        requested = signum  # Signal handlers never wait/reap or target raw PIDs.

    def signal_child(signum):
        # Popen owns this child. No wait/reap occurs between this live check and
        # signal; an exited but unreaped child keeps its PID unavailable for reuse.
        if child.poll() is None:
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, cancelled)
    deadline = time.monotonic() + wall_seconds
    if requested is not None:
        return 128 + requested
    # The guard owns a separate provider group so it can escalate the whole
    # provider group without killing itself or releasing admission before reap.
    child = subprocess.Popen(argv, close_fds=True, start_new_session=True)
    escalation = None
    try:
        while child.poll() is None:
            now = time.monotonic()
            if escalation is None and (requested is not None or now >= deadline):
                signal_child(requested or signal.SIGTERM)
                escalation = now + 3
            if escalation is not None and now >= escalation:
                signal_child(signal.SIGKILL)
                break
            time.sleep(0.02)
        result = child.wait()
    finally:
        # An interpreter exception cannot leave the owned child behind while a
        # normal guard exit would be reported as completed provider termination.
        if child.poll() is None:
            signal_child(signal.SIGTERM)
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                signal_child(signal.SIGKILL)
                # Kernel reap is not time-bounded; retain admission until exact
                # child completion, even after requesting a hard kill.
                child.wait()
    return result if result >= 0 else 128 - result


def main():
    if len(sys.argv) < 5 or sys.argv[3] != "--":
        return 2
    try:
        return run(sys.argv[4:], int(sys.argv[1]), float(sys.argv[2]))
    except (OSError, ValueError):
        return 127


if __name__ == "__main__":
    raise SystemExit(main())
