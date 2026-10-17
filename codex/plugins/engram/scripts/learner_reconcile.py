#!/usr/bin/env python3
"""Explicit legacy reconciliation commands; never provider/native invocation."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import uuid


from codex_learner import legacy_reconciliation


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "apply", "recover"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--evidence-directory", type=Path, help="Private reviewed bundle directory; required only for prepare")
    parser.add_argument("--package-root", required=True, type=Path)
    parser.add_argument("--candidate-store", required=True, type=Path)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--legacy-run-id")
    parser.add_argument("--reconciliation-id")
    parser.add_argument("--reviewed-bundle-sha256")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--plan-sha256")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        module = legacy_reconciliation
        paths = module.LegacyPaths(args.root, args.evidence_directory or args.root, args.package_root, args.candidate_store)
        if args.command == "prepare":
            if not all((args.legacy_run_id, args.reviewed_bundle_sha256, args.output, args.evidence_directory)):
                raise ValueError("legacy_reconciliation_missing_prepare_arguments")
            identity = args.reconciliation_id or str(uuid.uuid4())
            plan = module.prepare(paths, session_id=args.session_id, legacy_run_id=args.legacy_run_id,
                reviewed_bundle_sha256=args.reviewed_bundle_sha256, reconciliation_id=identity)
            if not args.output.is_absolute():
                raise ValueError("legacy_reconciliation_output_requires_absolute_path")
            if module.durable._directory(args.output.parent).st_mode & 0o077:
                raise ValueError("legacy_reconciliation_output_directory_not_private")
            module.coordinator._immutable(args.output, plan, "legacy_review_plan")
            result = {"status": "prepared", "id": identity,
                      "plan_sha256": module.durable.digest(module.durable.encode(plan)), "live_changes": False}
        elif args.command == "apply":
            if not args.plan or not args.plan_sha256:
                raise ValueError("legacy_reconciliation_missing_apply_arguments")
            raw, _ = module.durable._read(args.plan, maximum=module.MAX)
            if module.durable.digest(raw) != args.plan_sha256:
                raise ValueError("legacy_reconciliation_plan_pin_changed")
            plan = module._json(raw)
            if module._json(module._raw(plan["review"]))["session_id"] != args.session_id:
                raise ValueError("legacy_reconciliation_selection_changed")
            result = module.apply(paths, plan=plan, plan_sha256=args.plan_sha256)
        else:
            if not args.reconciliation_id or not args.plan_sha256:
                raise ValueError("legacy_reconciliation_missing_recover_arguments")
            result = module.recover(paths, session_id=args.session_id, reconciliation_id=args.reconciliation_id,
                                    plan_sha256=args.plan_sha256)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError) as error:
        reason = str(error) if str(error).startswith("legacy_reconciliation_") else "legacy_reconciliation_unavailable_or_changed"
        print(json.dumps({"status": "held", "reason": reason}, sort_keys=True))
        return 2


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
