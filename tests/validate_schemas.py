import copy
import json
from pathlib import Path

import jsonschema


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "read-only-analysis"
SCHEMAS = ROOT / "schemas"


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


pairs = {
    "workflow": load_json(EXAMPLES / "workflow.json"),
    "task": load_json(EXAMPLES / "tasks.json")[0],
    "result": load_json(EXAMPLES / "result.json"),
    "event": load_json(EXAMPLES / "event.json"),
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

print("SCHEMA VALID: 4 positive, 1 negative")
