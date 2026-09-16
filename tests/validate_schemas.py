import copy
import json
from pathlib import Path

import jsonschema


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "read-only-analysis"
SCHEMAS = ROOT / "schemas"
NATIVE_EXAMPLES = ROOT / "examples" / "native-task-responses"


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


pairs = {
    "workflow": load_json(EXAMPLES / "workflow.json"),
    "task": load_json(EXAMPLES / "tasks.json")[0],
    "result": load_json(EXAMPLES / "result.json"),
    "event": load_json(EXAMPLES / "event.json"),
    "dispatch": load_json(EXAMPLES / "dispatch.json"),
    "thread-observation": load_json(EXAMPLES / "thread-observation.json"),
    "wait-snapshot": load_json(NATIVE_EXAMPLES / "wait-snapshot.json"),
    "verification-receipt": load_json(EXAMPLES / "verification-receipt.json"),
    "action-plan": load_json(EXAMPLES / "action-plan.json"),
    "callback-receipt": load_json(EXAMPLES / "callback-receipt.json"),
    "external-action": load_json(EXAMPLES / "external-action.json"),
    "action-execution": load_json(EXAMPLES / "action-execution.json"),
    "worktree-binding": {
        "mode": "developer",
        "repository_root": "D:\\example-project",
        "worktree_path": "D:\\worktrees\\dev-001",
        "branch_name": "codex/dev-001",
        "head_revision": "a" * 40,
        "is_detached": False,
        "is_dirty": False,
        "inspected_at": "2026-09-16T00:00:00Z",
    },
    "git-operation": {
        "operation_id": "GIT-001", "operation": "stage", "authorization": "git-approved",
        "repository_root": "D:\\example-project", "worktree_path": "D:\\worktrees\\dev-001",
        "base_revision": "a" * 40, "branch_name": "codex/dev-001", "allowed_files": ["src/app.ps1"],
        "commit_message": None, "target_branch": None, "test_evidence": None, "review_evidence": None,
        "created_at": "2026-09-16T00:00:00Z",
    },
    "git-operation-receipt": {
        "operation_id": "GIT-001", "operation": "stage", "request_path": "D:\\state\\request.json",
        "request_sha256": "a" * 64, "repository_root": "D:\\example-project", "worktree_path": "D:\\worktrees\\dev-001",
        "branch_name": "codex/dev-001", "base_revision": "a" * 40, "end_revision": "a" * 40,
        "changed_files": ["src/app.ps1"], "test_evidence_sha256": None, "review_evidence_sha256": None,
        "push_performed": False, "force_performed": False, "status": "completed", "completed_at": "2026-09-16T00:00:00Z",
    },
    "git-action": {
        "git_action_id": "WF-001:1:DEV-001:create_worktree:1", "logical_key": "DEV-001:create_worktree",
        "task_id": "DEV-001", "operation": "create_worktree", "operation_id": "GIT-001",
        "controller_thread_id": "controller", "controller_host_id": "local", "controller_epoch": 1,
        "attempt": 1, "status": "prepared", "request_path": "D:\\state\\request.json", "request_sha256": "a" * 64,
        "receipt_path": None, "receipt_sha256": None, "resolution_evidence_path": None,
        "resolution_evidence_sha256": None, "error": None, "created_at": "2026-09-16T00:00:00Z",
        "completed_at": None, "failed_at": None, "cancelled_at": None,
    },
    "e2e-run": {
        "workflow_id": "WF-E2E-001",
        "repository_root": "D:\\e2e",
        "controller_thread_id": "controller",
        "tasks": [
            {"task_id": "ANALYSIS-001", "thread_id": "a", "role": "analyst", "worktree_path": "D:\\e2e", "base_revision": "a" * 40, "end_revision": "a" * 40, "callback_status": "acknowledged", "verification_status": "trusted"},
            {"task_id": "DEV-001", "thread_id": "d", "role": "developer", "worktree_path": "D:\\wt-dev", "base_revision": "a" * 40, "end_revision": "b" * 40, "callback_status": "acknowledged", "verification_status": "trusted"},
            {"task_id": "TEST-001", "thread_id": "t", "role": "tester", "worktree_path": "D:\\wt-test", "base_revision": "b" * 40, "end_revision": "b" * 40, "callback_status": "acknowledged", "verification_status": "trusted"},
            {"task_id": "REVIEW-001", "thread_id": "r", "role": "reviewer", "worktree_path": "D:\\wt-review", "base_revision": "b" * 40, "end_revision": "b" * 40, "callback_status": "acknowledged", "verification_status": "trusted"},
        ],
        "development": {"commit": "b" * 40, "changed_files": ["src/Greeting.ps1"]},
        "test": {"inspected_revision": "b" * 40, "checks": [{"name": "Pester", "status": "passed", "exit_code": 0}]},
        "review": {"inspected_revision": "b" * 40, "outcome": "passed", "findings": []},
        "created_at": "2026-09-16T00:00:00Z",
    },
}

for name, document in pairs.items():
    schema = load_json(SCHEMAS / f"{name}.schema.json")
    jsonschema.Draft202012Validator.check_schema(schema)
    jsonschema.validate(document, schema)

invalid_task = copy.deepcopy(pairs["task"])
invalid_task["repair_count"] = 2
task_schema = load_json(SCHEMAS / "task.schema.json")
try:
    jsonschema.validate(invalid_task, task_schema)
except jsonschema.ValidationError:
    pass
else:
    raise AssertionError("Invalid repair_count unexpectedly passed validation")

invalid_result = copy.deepcopy(pairs["result"])
invalid_result["changed_files"] = [{"scope": "this-task", "files": []}]
result_schema = load_json(SCHEMAS / "result.schema.json")
try:
    jsonschema.validate(invalid_result, result_schema)
except jsonschema.ValidationError:
    pass
else:
    raise AssertionError("Object changed_files entry unexpectedly passed validation")

print("SCHEMA VALID: 17 positive, 2 negative")
