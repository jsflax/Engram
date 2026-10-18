#!/usr/bin/env python3
"""Explicit reviewed residual recovery. No provider is launched.

prepare seals inputs and probes the trusted native scope without applying memory
operations. execute consumes that prepared generation once. recover only queries
retained operation status and publishes qualified metadata. continue-absent is
the explicit, separately selected authority to use a new writer generation for
the SAME retained operation IDs and bytes. Pre-marker incomplete evidence holds;
this CLI never adopts an orphan run as ordinary worker authority.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

from codex_learner import learner_settings, operation_probe
from codex_learner import residual_context as R
from codex_learner import residual_driver as D
from codex_learner import residual_publication as P
from codex_learner import native_executor as N

J, F = D.J, D.F


def require(ok, reason):
    if not ok:
        raise ValueError("residual_cli_" + reason)


class Coordination:
    """Existing worker -> provider -> enqueue locks, never created or chmodded.

These are coordination locks, not inherited native writer fences. The worker
and provider guards remain owned while enqueue may be released for execution.
"""
    def __init__(self, root):
        self.root, self.held = root, []

    @contextlib.contextmanager
    def _lock(self, path):
        J.durable._directory(path.parent)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        acquired = False
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and info.st_nlink == 1 and not info.st_mode & 0o077, "unsafe_coordination_lock")
            identity = J.durable._lock_identity(info)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("residual_cli_coordination_busy") from None
            acquired = True
            self.held.append((path, fd, identity))
            self.verify(enqueue=False)
            yield
        finally:
            if acquired:
                self.held.pop()
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    @contextlib.contextmanager
    def worker(self):
        with self._lock(self.root / "worker.lock"):
            with self._lock(self.root.parent / "learner-provider.lock"):
                yield self

    @contextlib.contextmanager
    def enqueue(self):
        require(len(self.held) == 2, "lock_order_changed")
        with self._lock(self.root / "enqueue.lock"):
            yield self.verify

    def verify(self, *, enqueue=True):
        expected = [self.root / "worker.lock", self.root.parent / "learner-provider.lock"]
        if enqueue:
            expected.append(self.root / "enqueue.lock")
            require([p for p, _, _ in self.held] == expected, "caller_locks_missing")
        else:
            require(bool(self.held) and [p for p, _, _ in self.held] ==
                    (expected + [self.root / "enqueue.lock"])[:len(self.held)], "lock_order_changed")
        for path, fd, identity in self.held:
            require(J.durable._lock_identity(path.lstat()) == J.durable._lock_identity(os.fstat(fd)) == identity,
                    "coordination_lock_changed")
        return True


def _paths(args, run_id):
    P._run_id(run_id)
    return R.ResidualPaths(args.root, args.root / "runs" / run_id,
                           args.config, args.package_root, args.candidate_store)


def _base_paths(args):
    for path in (args.root, args.config, args.package_root, args.candidate_store):
        require(path.is_absolute() and path.resolve(strict=True) == path, "untrusted_paths")
    J.durable._root(args.root)
    R.A._uuid(args.session_id, 7)


def _selected(context, args):
    require(context.plan["session_id"] == args.session_id, "session_changed")
    if args.review_sha256 is not None:
        require(context.review_sha256 == args.review_sha256, "review_changed")
    return context


def _load(args):
    require(args.run_id and args.manifest_sha256 and args.context_sha256, "missing_execution_pins")
    J._digest(args.manifest_sha256); J._digest(args.context_sha256)
    return _selected(R.load_context(_paths(args, args.run_id),
        manifest_sha256=args.manifest_sha256, context_sha256=args.context_sha256,
        runtime_profile=getattr(args, "runtime_compatibility", None)), args)


def _prepare(args, locks):
    require(args.review is not None and args.review_sha256 is not None
            and args.evidence_directory is not None, "missing_prepare_arguments")
    for path in (args.review, args.evidence_directory):
        require(path.is_absolute() and path.resolve(strict=True) == path, "untrusted_review_path")
    J._digest(args.review_sha256)
    raw, _ = J.durable._read(args.review, maximum=J.MAX_INPUT)
    require(J.sha256(raw) == args.review_sha256, "review_changed")
    plan = R.review_plan(J._json(raw))
    require(plan["session_id"] == args.session_id, "session_changed")
    R.capture_reports(plan, args.evidence_directory)
    run_id = args.run_id or dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex
    paths = _paths(args, run_id)
    with locks.enqueue():
        locks.verify()
        require(P.recovery_reference(args.root, args.session_id) is None, "existing_residual_recovery")
        require(not os.path.lexists(paths.run_dir), "run_already_exists")
        J.durable._mkdir(args.root / "runs")
        J.durable._mkdir(paths.run_dir)
        J.durable._mkdir(paths.run_dir / "workspace")
        paths.check()
        configuration, route = R.C._backend(paths.base())
        R._store_route(paths, route)
        binding = F.create(paths.run_dir, generation_id=str(uuid.uuid4()), owner_id=str(uuid.uuid4()))
        writer = F.acquire_shared(paths.run_dir, binding)
        try:
            locks.verify()
            scope = operation_probe.probe_scope(route["transport"], writer_fence=writer, expected_binding=binding)
            locks.verify()
            settings = learner_settings.bounded((configuration.get("settings") or {}).get("value", {}))
            context = R.seal_context(paths, reviewed_raw=raw, reviewed_sha256=args.review_sha256,
                evidence_directory=args.evidence_directory, host="codex", scope=scope, writer=writer,
                max_chars=settings["max_chars"], max_scan_bytes=settings["max_scan_bytes"])
            locks.verify()
        finally:
            writer.close()
    return {"status": "prepared", "run_id": run_id, "manifest_sha256": context.manifest_sha256,
            "context_sha256": context.context_sha256, "review_sha256": context.review_sha256,
            "operation_count": len(plan["operations"]), "memory_mutations_requested": 0,
            "cursor_changed": False, "provider_invoked": False, "successful_coverage": False}


def _recover(args, locks, *, continuation):
    with locks.enqueue():
        ref = P.recovery_reference(args.root, args.session_id)
        if ref is None:
            require(not continuation, "no_selected_recovery")
            return {"status": "no_selected_recovery", "provider_invoked": False}
        if continuation:
            _load(args)
        for flag, name in ((args.run_id, "run_id"), (args.manifest_sha256, "manifest_sha256"),
                           (args.context_sha256, "context_sha256"), (args.review_sha256, "review_sha256")):
            require(flag is None or flag == ref[name], "recovery_selection_changed")
        # Preserve the authenticated selection for content-free receipt reporting
        # if later status/publication validation holds this invocation.
        args.run_id, args.manifest_sha256 = ref["run_id"], ref["manifest_sha256"]
        args.context_sha256, args.review_sha256 = ref["context_sha256"], ref["review_sha256"]
        receipt = P.recover_locked(_paths(args, ref["run_id"]), session_id=args.session_id,
            verify_locks=locks.verify, allow_continuation=continuation,
            runtime_profile=getattr(args, "runtime_compatibility", None))
        return receipt or {"status": "already_reconciled", "run_id": ref["run_id"],
                           "provider_invoked": False, "successful_coverage": False}


def _execute(args, locks):
    context = _load(args)
    if R.reviewed(context.plan):
        return _execute_reviewed(context,args,locks)
    with locks.enqueue():
        require(P.recovery_reference(args.root, args.session_id) is None, "use_recover")
        # A pre-marker interrupted begin is inert evidence, never retry authority.
        require(not os.path.lexists(context.paths.run_dir / "residual-generation-000.json"),
                "incomplete_or_consumed_preparation")
        writer = F.acquire_shared(context.paths.run_dir, context.manifest["fencing"])
        try:
            driver = P.begin(context, writer=writer, verify_locks=locks.verify)
        except BaseException:
            writer.close()
            raise
    try:
        def validate(manifest, plan, phase):
            locks.verify(enqueue=False)
            return context.validate_inputs(manifest, plan, phase)
        driver.validate_inputs = validate
        execute = N.executor(driver, context.transport)
        for label in driver.operations:
            result = driver.dispatch(label, writer=writer, recoveries=[], execute=execute)
            if (label not in result["applied"] or result["invalid_operations"] or result["unchanged"]
                    or not result["execution_evidence_valid"] or result.get("current_inputs_validated") is False):
                break
    finally:
        # Close only. A native child copy must drain before EX recovery succeeds.
        writer.close()
    return _recover(args, locks, continuation=False)


def _execute_reviewed(context,args,locks):
    """Resume only the pinned complete plan; preserved old writes never enter it."""
    from codex_learner import planned_execution as E
    with locks.enqueue():
        ref=P.recovery_reference(args.root,args.session_id)
        if ref is not None:
            require(all(ref[key]==value for key,value in P._pin(context).items()),'selected_plan_changed')
            P._authorization(context);P._recover_marker(context,locks.verify)
        writer=F.drain_and_acquire_shared(context.paths.run_dir,context.manifest['fencing'],
            validate=lambda *_:locks.verify() and context.validate_marker())
        try:
            if ref is None:P.begin(context,writer=writer,verify_locks=locks.verify)
        except BaseException:
            writer.close();raise
    try:
        def validate(manifest,phase):
            locks.verify(enqueue=False)
            return context.validate_inputs(manifest,context.plan,phase)
        E.execute_plan(context.paths.run_dir,writer=writer,validate_inputs=validate,
                       execute=E.native_executor(context.paths.run_dir,context.transport))
    finally:writer.close()
    return _recover(args,locks,continuation=False)


def _retained_summary(args):
    """Report known receipt IDs after failure; never dispatch or grant authority."""
    try:
        context = _load(args)
        if R.reviewed(context.plan):
            from codex_learner import planned_execution as E
            value=E.inspect_plan(context.paths.run_dir)
            return {key:value[key] for key in ('memory_ids','status','applied_write_calls','unchanged_write_calls')}
        driver = D.ResidualDriver(context.paths.run_dir, manifest_sha256=context.manifest_sha256,
            review_sha256=context.review_sha256, validate_inputs=lambda *_: False)
        value = driver.summary()
        return {key: value[key] for key in ("memory_ids", "applied", "unchanged", "invalid_operations",
                                           "unsettled", "execution_evidence_valid")}
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        return {}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "execute", "recover", "continue-absent"))
    for name in ("root", "config", "package-root", "candidate-store"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--run-id")
    parser.add_argument("--review", type=Path)
    parser.add_argument("--review-sha256")
    parser.add_argument("--evidence-directory", type=Path)
    parser.add_argument("--manifest-sha256")
    parser.add_argument("--context-sha256")
    parser.add_argument("--runtime-compatibility", choices=("engram-0.15.1-validation-budget-v1", "engram-0.15.2-reviewed-accounting-v1"))
    args = parser.parse_args(argv)
    try:
        require(args.runtime_compatibility is None or args.command in ("recover", "continue-absent"),
                "runtime_compatibility_recovery_only")
        _base_paths(args)
        with Coordination(args.root).worker() as locks:
            if args.command == "prepare":
                result = _prepare(args, locks)
            elif args.command == "execute":
                result = _execute(args, locks)
            else:
                result = _recover(args, locks, continuation=args.command == "continue-absent")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError) as error:
        text = str(error)
        prefixes = ("residual_", "execution_", "operation_probe_", "writer_fence_", "migration_",
                    "legacy_reconciliation_")
        reason = text if text.startswith(prefixes) and re.fullmatch(r"[a-z][a-z0-9_]{0,150}", text) else "residual_cli_unavailable_or_changed"
        result = {"status": "held", "reason": reason, "provider_invoked": False,
                  "historical_provider_success": False, "successful_coverage": False, **_retained_summary(args)}
        print(json.dumps(result, sort_keys=True))
        return 2


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
