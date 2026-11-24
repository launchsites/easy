#!/usr/bin/env python3
"""Verify AI allowance recovery in two native tester processes with fake transport."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check-policy-ack", action="store_true")
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{40}", args.revision) is None:
        parser.error("Provide the full audited source revision.")

    root = Path(__file__).resolve().parents[2]
    tests = Path("tool/benchmark/ai_allowance_process")
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="easy-ai-allowance-") as folder:
        process = subprocess.run(
            [args.flutter, "test", "--no-pub", "--concurrency", "2",
             "--reporter", "expanded", tests / "peer_a_test.dart", tests / "peer_b_test.dart"],
            cwd=root, env={**os.environ, "EASY_ALLOWANCE_PROCESS_FIXTURE": folder,
                           "EASY_ALLOWANCE_POLICY_ACK": str(int(args.check_policy_ack))},
            capture_output=True, text=True, timeout=180,
        )
        if process.returncode:
            raise RuntimeError(f"The device allowance fixture failed.\n{process.stdout}\n{process.stderr}")
        checks = json.loads((Path(folder) / "verified.json").read_text())
    report = {"source_revision": args.revision, "transport": "synthetic",
              "client_processes": 2, "elapsed_seconds": round(time.monotonic() - started, 2),
              "checks": checks}
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
