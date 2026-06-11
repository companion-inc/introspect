#!/usr/bin/env python3
"""Validate the local agent-loop skill library."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SKILLS_DIR = Path(os.path.expanduser(os.environ.get("AGENTS_MD_SKILLS_DIR", str(REPO / "skills"))))
INDEX = SKILLS_DIR / "index.json"
FORBIDDEN = (
    "when user asks",
    "when_to_apply",
    "when to apply",
)


def fail(message: str) -> int:
    print(f"validate-skills: {message}", file=sys.stderr)
    return 1


def frontmatter(text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}
    data: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip().strip('"')
    return data


def main() -> int:
    try:
        index = json.loads(INDEX.read_text())
    except Exception as exc:
        return fail(f"cannot read {INDEX}: {exc}")

    skills = index.get("skills")
    if not isinstance(skills, list) or not skills:
        return fail("skills/index.json must contain a non-empty skills list")

    seen: set[str] = set()
    for entry in skills:
        if not isinstance(entry, dict):
            return fail("each skill index entry must be an object")

        skill_id = entry.get("id")
        path_value = entry.get("path")
        status = entry.get("status")
        signals = entry.get("activation_signals")

        if not skill_id or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", skill_id):
            return fail(f"invalid skill id: {skill_id!r}")
        if skill_id in seen:
            return fail(f"duplicate skill id: {skill_id}")
        seen.add(skill_id)

        if status not in {"candidate", "active", "deprecated"}:
            return fail(f"{skill_id}: invalid status {status!r}")
        if not isinstance(signals, list) or not all(isinstance(s, str) and s for s in signals):
            return fail(f"{skill_id}: activation_signals must be non-empty strings")

        raw_path = Path(str(path_value))
        path = raw_path if raw_path.is_absolute() else SKILLS_DIR.parent / raw_path
        if not path.exists():
            return fail(f"{skill_id}: missing file {path_value}")
        if path.name != "SKILL.md":
            return fail(f"{skill_id}: path must end in SKILL.md")

        text = path.read_text()
        lower = text.lower()
        for phrase in FORBIDDEN:
            if phrase in lower:
                return fail(f"{skill_id}: forbidden phrase {phrase!r}")

        meta = frontmatter(text)
        if meta.get("name") != skill_id:
            return fail(f"{skill_id}: frontmatter name must match id")
        if not meta.get("description"):
            return fail(f"{skill_id}: frontmatter description is required")

    print(f"validate-skills: ok ({len(skills)} skills)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
