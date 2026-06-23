#!/usr/bin/env python3
"""Regression checks for the simple Introspect run command."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "bin" / "introspect"


def fail(message: str) -> None:
    raise SystemExit(f"test-introspect-run: {message}")


def run_cli(home: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home.parent),
            "INTROSPECT_HOME": str(home),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return subprocess.run(
        [str(CLI), *args],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-run-") as tmp:
        base = Path(tmp)
        home = base / ".introspect"
        for host in ("codex", "claude", "opencode"):
            transcript = base / "sessions" / host / "session-test.jsonl"
            transcript.parent.mkdir(parents=True)
            transcript.write_text(
                '{"type":"session_meta","payload":{"id":"'
                + host
                + '-session","cwd":"/tmp/project"}}\n'
                '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"remember to use Introspect for this path"}]}}\n'
            )

            first = run_cli(
                home,
                "run",
                "--host",
                host,
                "--event",
                "manual",
                "--transcript-path",
                str(transcript),
                "--force",
                "--json",
            )
            if first.returncode != 0:
                fail(first.stderr or first.stdout)
            result = json.loads(first.stdout)
            if result.get("status") != "no_change":
                fail(f"expected no_change for {host}, got {result}")
            if result.get("message") != "No high-signal memory updates.":
                fail(f"unexpected message for {host}: {result}")
            if result.get("classifier_training") is not False:
                fail(f"Introspect must not train classifiers for {host}")
            if result.get("mutated_targets") != []:
                fail(f"unexpected mutated targets for {host}: {result.get('mutated_targets')}")

            run_path = home / "runs" / result["run_id"]
            if not (run_path / "result.json").is_file():
                fail(f"missing result artifact for {host}")
            if not (run_path / "summary.md").is_file():
                fail(f"missing summary artifact for {host}")

            index_path = home / "introspect" / host / "transcript-index.json"
            index = json.loads(index_path.read_text())
            if str(transcript) not in index.get("transcripts", {}):
                fail(f"transcript not indexed for {host}")

            skipped = run_cli(
                home,
                "run",
                "--host",
                host,
                "--event",
                "stop",
                "--transcript-path",
                str(transcript),
                "--min-turns",
                "10",
                "--json",
            )
            if skipped.returncode != 0:
                fail(skipped.stderr or skipped.stdout)
            skipped_payload = json.loads(skipped.stdout)
            if skipped_payload.get("status") != "skipped":
                fail(f"expected skipped cadence result for {host}, got {skipped_payload}")

    print("test-introspect-run: ok")


if __name__ == "__main__":
    main()
