"""Portable residual fixtures. All review identities/content are synthetic.

Paths come from the repository suite harness, never the caller cwd or a private
review bundle. Every runtime import must resolve to the assembled repository implementation.
"""
import importlib
import importlib.util
from pathlib import Path
import sys

# Locate the suite harness without executing its process-wide HOME/CODEX_HOME
# fixture setup again in a fresh recovery child. Both processes must inherit the
# same sealed launch environment. These path rules mirror suite_support.
_suite = importlib.util.find_spec("suite_support")
if _suite is None or not _suite.origin:
    raise RuntimeError("Residual tests require the repository suite_support module")
TEST_ROOT = Path(_suite.origin).resolve().parent
REPOSITORY_ROOT = TEST_ROOT.parents[1]
PLUGIN_ROOT = REPOSITORY_ROOT / "codex/plugins/engram"
if not (PLUGIN_ROOT / ".codex-plugin/plugin.json").is_file():
    raise RuntimeError("Residual tests require the repository plugin")
TEMP_ROOT = TEST_ROOT / ".tmp"
if TEMP_ROOT.is_symlink():
    raise RuntimeError("Residual fixture directory must not be a symlink")

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))


def runtime(name):
    module = importlib.import_module("codex_learner." + name)
    expected = PLUGIN_ROOT / "scripts/codex_learner" / (name + ".py")
    if Path(module.__file__).resolve() != expected.resolve():
        raise RuntimeError("Residual tests require the assembled repository plugin")
    return module


D = runtime("residual_driver")
N = runtime("native_executor")
J = D.J


def synthetic_review():
    """Return a fresh schema-complete synthetic review, with no imported facts."""
    sid = "019b7a00-0000-7123-8000-000000000071"
    memory = "41111111-2222-4333-8444-555555555555"
    mapping = {1: "R2", 2: "R2", 12: "R3", 14: "R3", 15: "R4", 16: "R5", 17: "R1"}
    messages = ["Synthetic reviewed assistant statement %02d." % i for i in range(1, 18)]
    dispositions = []
    for index, body in enumerate(messages, 1):
        entry = {"index": index, "segment_sha256": J.sha256(body.encode())}
        if index in mapping:
            entry.update(disposition="reviewed_residual", operations=[mapping[index]])
        elif index in (11, 13):
            entry.update(disposition="preserved_applied_update", memory_ids=[memory])
        else:
            entry.update(disposition="dated_progress_no_new_durable_fact")
        dispositions.append(entry)
    operations = []
    for index in range(1, 6):
        label = "R" + str(index)
        arguments = {"project": "Engram", "topic": "learner-recovery",
                     "content": "Synthetic reviewed residual fact " + label + ".",
                     "source": "codex-session:" + sid, "is_private": True, "force": False}
        operations.append({"id": label, "tool": "remember", "arguments": arguments,
            "arguments_canonical_sha256": J.sha256(J.encode(arguments)),
            "messages": [i for i, selected in mapping.items() if selected == label],
            "review_status": "reviewed_exact_payload", "origin": "synthetic_test_only", "ttl": "none"})
    return {"schema_version": 1, "kind": "reviewed_fresh_residual_plan",
        "status": "reviewed_candidate_not_live_dispatch_authority", "session_id": sid,
        "legacy_run_id": "20260103T083200Z-b8af2a1f05fd497394bd99ea768a54cb",
        "source": {"identity": {"scheme": "macos_volume_uuid_inode_v1",
            "volume_uuid": "11111111-2222-4333-8444-555555555555", "inode": 4242},
            "start": 100, "end": 200, "interval_sha256": J.sha256(b"synthetic interval"),
            "excerpt_sha256": J.sha256(b"synthetic excerpt"),
            "parser_sha256": J.sha256(b"synthetic parser"), "visible_messages": 17},
        "operations": operations, "message_dispositions": dispositions,
        "preserve_without_replay": {"tool": "update", "memory_ids": [memory], "messages_represented": [11, 13]},
        "exact_rows_inspected": [memory],
        "prior_successful_runs": ["20260103T073200Z-a8af2a1f05fd497394bd99ea768a54cb"],
        "retained_inputs": {}, "approved_proposal_sha256": J.sha256(b"synthetic proposal"),
        "review_adoption_sha256": J.sha256(b"synthetic adoption"),
        "review_authority": "synthetic_fixture_only", "qualification": {"live_authority": False},
        "bounded_duplicate_conclusion": "Only synthetic selected rows are represented.",
        "new_mutations_performed": 0, "cursor_or_gate_changed": False}
