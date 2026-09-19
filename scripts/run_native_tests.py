#!/usr/bin/env python3
"""Run the unchanged native test command with bounded stall diagnostics."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def processes():
    # comm excludes arguments and environments (which can contain credentials).
    output = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,ppid=,pgid=,lstart=,stat=,comm="],
        text=True, timeout=2)
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 9)
        if len(fields) == 10:
            pid, parent, group = map(int, fields[:3])
            result[pid] = {"pid": pid, "parent": parent, "group": group,
                           "started": " ".join(fields[3:8]), "state": fields[8],
                           "command": fields[9]}
        elif line.strip():
            raise RuntimeError("Unparseable process inventory row")
    if not result:
        raise RuntimeError("Empty process inventory")
    return result


def identity(process):
    # Executing another binary preserves process identity.
    return process["pid"], process["started"]


class Runner:
    def __init__(self, command, directory, *, timeout=1800, silence=300,
                 log_limit=64 * 1024**2, sample_tool="/usr/bin/sample",
                 sample_timeout=10, sample_seconds=5, cleanup_grace=5,
                 console=None):
        self.command = command
        self.directory = Path(directory)
        self.timeout, self.silence = timeout, silence
        self.log_limit = log_limit
        self.sample_tool = sample_tool
        self.sample_timeout, self.sample_seconds = sample_timeout, sample_seconds
        self.cleanup_grace = cleanup_grace
        self.console = sys.stdout.buffer if console is None else console
        self.known = {}
        self.errors, self.diagnostics, self.signals = [], [], []
        self.output_bytes = self.log_bytes = 0
        self.reader_error = None
        self.group_closed = False

    def refresh(self):
        current = {pid: item for pid, item in processes().items() if "Z" not in item["state"]}
        # Remember descendants even after reparenting, but never reuse a stale
        # PID after its start identity changes.
        owned = {pid: item for pid, item in current.items()
                 if pid in self.known and identity(item) == identity(self.known[pid])}
        # Popen created this private group. Stop following its number forever
        # once the original group disappears, so a later group cannot be adopted.
        root = current.get(self.child.pid)
        if root and self.child.pid in self.known and identity(root) != identity(self.known[self.child.pid]):
            self.group_closed = True
        group = [item for item in current.values() if item["group"] == self.child.pid]
        if not self.group_closed:
            if group:
                owned.update((item["pid"], item) for item in group)
            elif self.child.poll() is not None:
                self.group_closed = True
        while True:
            children = {pid: item for pid, item in current.items()
                        if item["parent"] in owned and pid not in owned}
            if not children:
                break
            owned.update(children)
        self.known.update(owned)
        return owned

    def drain(self):
        try:
            with (self.directory / "output.log").open("xb") as output:
                while True:
                    chunk = os.read(self.child.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    self.last_output = time.monotonic()
                    self.output_bytes += len(chunk)
                    kept = chunk[:max(0, self.log_limit - self.log_bytes)]
                    output.write(kept)
                    output.flush()
                    self.log_bytes += len(kept)
                    if self.console is not None:
                        try:
                            self.console.write(chunk)
                            self.console.flush()
                        except (BrokenPipeError, OSError):
                            # A closed console must not stop draining the child.
                            self.console = None
        except Exception as error:
            self.reader_error = repr(error)

    def capture(self, reason, deadline):
        record = {"reason": reason, "elapsed_seconds": time.monotonic() - self.started,
                  "samples": [], "errors": []}
        self.diagnostics.append(record)
        prefix = self.directory / (str(len(self.diagnostics)) + "-" + reason)
        try:
            owned = self.refresh()
            (prefix.with_suffix(".json")).write_text(json.dumps(
                {"processes": list(owned.values())[:256]}, indent=2) + "\n")
            # Prefer native test executables over SwiftPM and helper processes.
            candidates = sorted(owned.values(), key=lambda item: (
                not any(name in item["command"].lower()
                        for name in (".xctest", "xctest", "engrampackagetests", "swiftpm-testing")),
                item["pid"] == self.child.pid, item["pid"]))[:3]
            for item in candidates:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self.signals:
                    break
                current = processes().get(item["pid"])
                if current is None or identity(current) != identity(item):
                    continue
                path = Path(str(prefix) + "-" + str(item["pid"]) + ".sample.txt")
                sample = {"process": item, "path": path.name}
                record["samples"].append(sample)
                try:
                    result = subprocess.run(
                        [self.sample_tool, str(item["pid"]), str(self.sample_seconds),
                         "10", "-file", str(path)],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=min(self.sample_timeout, max(0.01, remaining)))
                    sample["exit_code"] = result.returncode
                except (OSError, subprocess.TimeoutExpired) as error:
                    sample["error"] = repr(error)
                finally:
                    if path.exists():
                        # Keep each stack artifact bounded as well as output.log.
                        with path.open("r+b") as output:
                            if output.seek(0, os.SEEK_END) > 4 * 1024**2:
                                output.truncate(4 * 1024**2)
                                sample["truncated"] = True
        except Exception as error:
            record["errors"].append(repr(error))

    def cleanup(self, deadline):
        receipt = {"signals": [], "remaining": [], "errors": []}
        for number in (signal.SIGTERM, signal.SIGKILL):
            if time.monotonic() >= deadline:
                break
            try:
                owned = self.refresh()
                # Children first, then their launcher. Revalidate every PID
                # against a fresh snapshot before each signaling phase.
                for pid, item in sorted(owned.items(), key=lambda pair: pair[0] == self.child.pid):
                    try:
                        os.kill(pid, number)
                        receipt["signals"].append({"pid": pid, "started": item["started"],
                                                   "signal": signal.Signals(number).name})
                    except ProcessLookupError:
                        pass
                until = min(deadline, time.monotonic() + self.cleanup_grace)
                while time.monotonic() < until:
                    self.child.poll()  # Reap our direct child before inspecting ps.
                    if not self.refresh():
                        break
                    time.sleep(0.05)
            except Exception as error:
                receipt["errors"].append(repr(error))
                # An unreadable inventory removes authority to target unknown
                # descendants, but Popen still owns its unreaped direct child.
                if self.child.poll() is None:
                    try:
                        if number == signal.SIGTERM:
                            self.child.terminate()
                        else:
                            self.child.kill()
                        receipt["signals"].append({"pid": self.child.pid,
                                                   "signal": signal.Signals(number).name,
                                                   "direct_child_fallback": True})
                        self.child.wait(timeout=max(0.01, min(
                            self.cleanup_grace, deadline - time.monotonic())))
                    except subprocess.TimeoutExpired:
                        pass
                    except Exception as fallback_error:
                        receipt["errors"].append(repr(fallback_error))
        try:
            self.child.wait(timeout=max(0.01, min(1, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            receipt["errors"].append("Direct child did not exit")
        try:
            receipt["remaining"] = list(self.refresh().values())
        except Exception as error:
            receipt["errors"].append(repr(error))
        return receipt

    def run(self):
        self.directory.mkdir(parents=True, exist_ok=False)
        self.started = self.last_output = time.monotonic()
        runtime_deadline = self.started + self.timeout
        # Independent of the workflow's 32-minute timeout; leave room for upload.
        final_deadline = runtime_deadline + 90
        self.child = subprocess.Popen(self.command, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      start_new_session=True)
        reader = threading.Thread(target=self.drain, daemon=True)
        reader.start()
        previous = {}
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, lambda number, frame: self.signals.append(number))
        reason, code, child_code = "exit", None, None
        silence_captured = False
        next_snapshot = 0
        try:
            while True:
                now = time.monotonic()
                if now >= next_snapshot:
                    self.refresh()
                    next_snapshot = now + 1
                child_code = self.child.poll()
                if child_code is not None and child_code != 0:
                    code = child_code if child_code >= 0 else 128 - child_code
                    break
                if self.signals:
                    reason, code = "signal", 128 + self.signals[0]
                    break
                if self.reader_error:
                    raise RuntimeError("Output reader failed: " + self.reader_error)
                now = time.monotonic()
                if now >= runtime_deadline:
                    reason, code = "timeout", 124
                    break
                if child_code == 0:
                    code = 0
                    break
                if not silence_captured and now - self.last_output >= self.silence:
                    silence_captured = True
                    self.capture("silence", min(now + 35, runtime_deadline))
                time.sleep(0.25)
            if code and not self.signals:
                self.capture(reason, min(time.monotonic() + 35, final_deadline - 15))
        except Exception as error:
            reason, code = "supervisor_error", 125
            self.errors.append(repr(error))
        finally:
            cleanup = self.cleanup(min(time.monotonic() + 15, final_deadline))
            reader.join(timeout=2)
            reader_complete = not reader.is_alive()
            self.child.stdout.close()
            for number, handler in previous.items():
                signal.signal(number, handler)
            if not code and self.signals:
                reason, code = "signal", 128 + self.signals[0]
            if not code and (cleanup["remaining"] or cleanup["errors"] or
                             not reader_complete or self.reader_error):
                code = 125
            receipt = {"command": self.command, "runtime_budget_seconds": self.timeout,
                       "silence_threshold_seconds": self.silence, "reason": reason,
                       "child_exit_code": self.child.returncode, "exit_code": code,
                       "elapsed_seconds": time.monotonic() - self.started,
                       "output_bytes": self.output_bytes, "saved_log_bytes": self.log_bytes,
                       "log_truncated": self.output_bytes > self.log_bytes,
                       "reader_complete": reader_complete, "reader_error": self.reader_error,
                       "diagnostics": self.diagnostics, "cleanup": cleanup,
                       "signals_received": self.signals, "errors": self.errors}
            (self.directory / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--diagnostics-dir", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=1800)
    parser.add_argument("--silence-seconds", type=float, default=300)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout_seconds <= 0 or args.silence_seconds <= 0:
        parser.error("A command and positive runtime/silence budgets are required")
    return Runner(command, args.diagnostics_dir, timeout=args.timeout_seconds,
                  silence=args.silence_seconds).run()


if __name__ == "__main__":
    sys.exit(main())
