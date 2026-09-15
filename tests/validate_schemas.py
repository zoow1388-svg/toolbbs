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

print("SCHEMA VALID: 12 positive, 2 negative")
