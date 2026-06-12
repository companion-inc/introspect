#!/usr/bin/env python3
"""Fail if an always-loaded prompt contains warning/refusal priming words."""

from __future__ import annotations

import re
import sys
from pathlib import Path


DEFAULT_PATTERNS = {
    "caveat": r"\bcaveats?\b",
    "disclaim": r"\bdisclaim(?:er|ers|ing)?\b",
    "front-load-safety": r"\bfront-load\s+safety\b",
    "ip-category": r"\bIP\b|\btrademark(?:s|ed)?\b|\bToS\b",
    "legal-category": r"\blegal\b|\bpolicy\b",
    "lecture": r"\blectur(?:e|es|ing)\b",
    "moralize": r"\bmorali[sz](?:e|es|ing)\b",
    "refusal": r"\brefus(?:e|al|als|ing)\b|\bI won't\b",
    "risk": r"\brisk(?:s|y)?\b",
    "safety-category": r"\bsafety\b",
    "warning": r"\bwarn(?:ing|ings)?\b",
}


ALLOWLIST = {
    "AGENTS.md": {
        # Existing browser-control wording; not related to user-facing safety preambles.
        "prompt": [r"browser \"always confirm\" policy"],
    }
}


def line_allowed(path: Path, line: str) -> bool:
    rules = ALLOWLIST.get(path.name, {})
    return any(re.search(pattern, line, flags=re.IGNORECASE) for pattern in rules.get("prompt", ()))


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check-prompt-priming.py PROMPT.md [...]", file=sys.stderr)
        return 2

    failures: list[str] = []
    for raw_path in sys.argv[1:]:
        path = Path(raw_path)
        text = path.read_text()
        for lineno, line in enumerate(text.splitlines(), 1):
            if line_allowed(path, line):
                continue
            for name, pattern in DEFAULT_PATTERNS.items():
                if re.search(pattern, line, flags=re.IGNORECASE):
                    failures.append(f"{path}:{lineno}: {name}: {line.strip()}")

    if failures:
        print("check-prompt-priming: found loaded warning/refusal vocabulary", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1

    print(f"check-prompt-priming: ok ({len(sys.argv) - 1} prompt files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
