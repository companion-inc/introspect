#!/usr/bin/env python3
"""Regression checks for agent prompt and skill surface classification."""

from __future__ import annotations

import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "hooks" / "trigger-worker.py"


def fail(message: str) -> None:
    raise SystemExit(f"test-surface-scopes: {message}")


def contains_path(path: Path, root: Path) -> bool:
    path_s = str(path)
    root_s = str(root)
    return path_s == root_s or path_s.startswith(root_s + "/")


class SurfaceHarness:
    def __init__(self, home: Path, introspect_home: Path, repo: Path, include_runtime: bool = False):
        self.home = home
        self.introspect_home = introspect_home
        self.repo = repo
        self.include_runtime = include_runtime

    def scan_roots(self) -> list[Path]:
        runtime_roots = [self.repo] if self.include_runtime else []
        return runtime_roots + [
            self.introspect_home,
            self.home / "Projects",
            self.home / "Companion" / "Code",
            self.home / "Documents" / "Codex",
            self.home / ".codex",
            self.home / ".claude",
            self.home / ".agents",
            self.home / ".config" / "opencode",
        ]

    @staticmethod
    def is_agent_prompt_file(path: Path) -> bool:
        if path.name in {"AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md"}:
            return True
        return "/.claude/rules/" in str(path) and path.name.endswith(".md")

    @staticmethod
    def is_skill_file(path: Path) -> bool:
        return path.name == "SKILL.md" and "/skills/" in str(path)

    def is_project_root(self, path: Path) -> bool:
        marker_files = [
            ".git",
            "package.json",
            "pyproject.toml",
            "Cargo.toml",
            "AGENTS.md",
            "CLAUDE.md",
        ]
        if any((path / marker).exists() for marker in marker_files):
            return True
        return path.exists() and any(
            child.name.endswith(".xcodeproj") or child.name.endswith(".xcworkspace")
            for child in path.iterdir()
        )

    def project_root(self, path: Path) -> Path:
        path = path.resolve()
        if contains_path(path, self.introspect_home):
            return self.introspect_home
        opencode_root = self.home / ".config" / "opencode"
        if contains_path(path, opencode_root):
            return opencode_root
        for name in [".codex", ".claude", ".agents"]:
            root = self.home / name
            if contains_path(path, root):
                return root

        floor_paths = {root.resolve() for root in self.scan_roots()}
        current = path.parent
        while current != self.home and current != current.parent:
            if self.is_project_root(current) or current in floor_paths:
                return current
            current = current.parent
        return path.parent

    def relative_path(self, root: Path, path: Path) -> str:
        root_s = str(root.resolve())
        path_s = str(path.resolve())
        if path_s == root_s:
            return path.name
        if path_s.startswith(root_s + "/"):
            return path_s[len(root_s) + 1 :]
        return path_s

    def scope(self, path: Path, is_skill: bool) -> str:
        path_s = str(path.resolve())
        home_s = str(self.home.resolve())
        introspect_s = str(self.introspect_home.resolve())
        if path_s.startswith(introspect_s + "/skills/"):
            return "Introspect user skill"
        if path_s == introspect_s or path_s.startswith(introspect_s + "/"):
            return "Introspect home prompt" if path.name == "AGENTS.md" else "Introspect home"
        if path_s.startswith(home_s + "/.codex/"):
            return "Codex global override" if path.name == "AGENTS.override.md" else "Codex global"
        if path_s.startswith(home_s + "/.agents/skills/"):
            return "Codex/OpenCode user skill"
        if path_s.startswith(home_s + "/.claude/skills/"):
            return "Claude personal skill"
        if path_s.startswith(home_s + "/.claude/rules/"):
            return "Claude user rule"
        if path_s.startswith(home_s + "/.claude/"):
            return "Claude user"
        if path_s.startswith(home_s + "/.config/opencode/skills/"):
            return "OpenCode user skill"
        if path_s.startswith(home_s + "/.config/opencode/"):
            return "OpenCode global"
        if is_skill:
            if "/.agents/skills/" in path_s:
                return "Codex/OpenCode project skill"
            if "/.claude/skills/" in path_s:
                return "Claude project skill"
            if "/.opencode/skills/" in path_s:
                return "OpenCode project skill"
            return "Repo skill"
        if "/.claude/rules/" in path_s:
            return "Claude project rule"
        if path.name == "AGENTS.override.md":
            return "Codex project override"
        if path.name == "AGENTS.md":
            return "Codex project append"
        if path.name == "CLAUDE.local.md":
            return "Claude local append"
        if path.name == "CLAUDE.md":
            return "Claude project append"
        return "Agent file"

    def record(self, path: Path) -> tuple[str, str, Path]:
        is_skill = self.is_skill_file(path)
        if not (self.is_agent_prompt_file(path) or is_skill):
            fail(f"{path} is not a recognized surface")
        root = self.project_root(path)
        return self.scope(path, is_skill), self.relative_path(root, path), root


def assert_source_contract() -> None:
    if not SOURCE.exists():
        return
    source = SOURCE.read_text(encoding="utf-8")
    required = [
        '{"AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md"}',
        'path_contains(path, (".claude", "rules"))',
        'name == "SKILL.md" and "skills" in path.parts',
        'home / ".config" / "opencode"',
        'should_skip_surface_directory(entry)',
        'home / ".codex"',
        'home / ".claude"',
        'home / ".agents"',
    ]
    for needle in required:
        if needle not in source:
            fail(f"missing source contract: {needle}")


def touch(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# test\n", encoding="utf-8")
    return path


def main() -> None:
    assert_source_contract()
    with tempfile.TemporaryDirectory(prefix="introspect-surface-") as tmp:
        base = Path(tmp)
        home = base / "home"
        introspect_home = home / ".introspect"
        repo = base / "app" / "Contents" / "Resources"
        project = home / "Companion" / "Code" / "demo"
        home.mkdir()
        repo.mkdir(parents=True)
        introspect_home.mkdir(parents=True)
        touch(project / "package.json")
        harness = SurfaceHarness(home=home, introspect_home=introspect_home, repo=repo)

        cases = [
            (touch(introspect_home / "AGENTS.md"), "Introspect home prompt", "AGENTS.md", introspect_home),
            (touch(introspect_home / "skills" / "private" / "SKILL.md"), "Introspect user skill", "skills/private/SKILL.md", introspect_home),
            (touch(home / ".codex" / "AGENTS.md"), "Codex global", "AGENTS.md", home / ".codex"),
            (touch(home / ".codex" / "AGENTS.override.md"), "Codex global override", "AGENTS.override.md", home / ".codex"),
            (touch(home / ".agents" / "skills" / "global" / "SKILL.md"), "Codex/OpenCode user skill", "skills/global/SKILL.md", home / ".agents"),
            (touch(home / ".claude" / "CLAUDE.md"), "Claude user", "CLAUDE.md", home / ".claude"),
            (touch(home / ".claude" / "skills" / "personal" / "SKILL.md"), "Claude personal skill", "skills/personal/SKILL.md", home / ".claude"),
            (touch(home / ".claude" / "rules" / "style.md"), "Claude user rule", "rules/style.md", home / ".claude"),
            (touch(home / ".config" / "opencode" / "AGENTS.md"), "OpenCode global", "AGENTS.md", home / ".config" / "opencode"),
            (touch(home / ".config" / "opencode" / "skills" / "personal" / "SKILL.md"), "OpenCode user skill", "skills/personal/SKILL.md", home / ".config" / "opencode"),
            (touch(project / "AGENTS.md"), "Codex project append", "AGENTS.md", project),
            (touch(project / "nested" / "AGENTS.override.md"), "Codex project override", "nested/AGENTS.override.md", project),
            (touch(project / "CLAUDE.md"), "Claude project append", "CLAUDE.md", project),
            (touch(project / "CLAUDE.local.md"), "Claude local append", "CLAUDE.local.md", project),
            (touch(project / ".agents" / "skills" / "codex-project" / "SKILL.md"), "Codex/OpenCode project skill", ".agents/skills/codex-project/SKILL.md", project),
            (touch(project / ".claude" / "skills" / "claude-project" / "SKILL.md"), "Claude project skill", ".claude/skills/claude-project/SKILL.md", project),
            (touch(project / ".opencode" / "skills" / "opencode-project" / "SKILL.md"), "OpenCode project skill", ".opencode/skills/opencode-project/SKILL.md", project),
            (touch(project / ".claude" / "rules" / "project-rule.md"), "Claude project rule", ".claude/rules/project-rule.md", project),
        ]

        for path, expected_scope, expected_relative, expected_root in cases:
            scope, relative, root = harness.record(path)
            expected_root = expected_root.resolve()
            if (scope, relative, root) != (expected_scope, expected_relative, expected_root):
                fail(
                    f"{path}: got {(scope, relative, root)}, "
                    f"expected {(expected_scope, expected_relative, expected_root)}"
                )

        singular = touch(project / "AGENT.md")
        if harness.is_agent_prompt_file(singular):
            fail("singular AGENT.md must stay unrecognized; supported prompt file is AGENTS.md")

    print(f"test-surface-scopes: ok ({len(cases)} cases)")


if __name__ == "__main__":
    main()
