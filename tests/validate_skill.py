from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "skill" / "codex-project-orchestrator"
skill_md = SKILL / "SKILL.md"

content = skill_md.read_text(encoding="utf-8")
if not content.startswith("---\n"):
    raise AssertionError("SKILL.md must start with YAML frontmatter")

parts = content.split("---\n", 2)
if len(parts) != 3:
    raise AssertionError("SKILL.md frontmatter is not closed")

metadata = yaml.safe_load(parts[1])
if not isinstance(metadata, dict):
    raise AssertionError("SKILL.md frontmatter must be an object")
if set(metadata) != {"name", "description"}:
    raise AssertionError("SKILL.md frontmatter must contain only name and description")
if metadata["name"] != SKILL.name:
    raise AssertionError("Skill name must match its directory")
if not isinstance(metadata["description"], str) or not metadata["description"].strip():
    raise AssertionError("Skill description must not be empty")
if not parts[2].strip():
    raise AssertionError("SKILL.md body must not be empty")

version = (SKILL / "VERSION").read_text(encoding="utf-8").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise AssertionError(f"Invalid Skill version: {version}")

print(f"SKILL VALID: codex-project-orchestrator {version}")
