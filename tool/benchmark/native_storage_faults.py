#!/usr/bin/env python3
"""Inject kernel write failures into a disposable native Easy workspace."""

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
WORKER = Path("tool/benchmark/storage_capacity_worker_test.dart")
PHASES = ("seed", "limited", "read-only", "retry", "reopen")


def run_phase(arguments, fixture, phase):
    environment = os.environ.copy()
    environment.update({
        "EASY_STORAGE_CAPACITY_FIXTURE": str(fixture),
        "EASY_STORAGE_CAPACITY_PHASE": phase,
    })
    command = [arguments.flutter, "test", "--no-pub", "--reporter", "expanded", str(WORKER)]
    trace = fixture.parent / "limit.trace"
    if phase == "limited" and arguments.trace:
        command = [
            arguments.trace, "-ff", "-yy", "-s", "0", "-e",
            "trace=write,pwrite64,ftruncate", "-o", str(trace), *command,
        ]
    process = subprocess.run(
        command, cwd=ROOT, env=environment, capture_output=True, text=True, timeout=300,
    )
    if process.returncode:
        raise RuntimeError(f"{phase} failed.\n{process.stdout}\n{process.stderr}")
    result_path = fixture / f"{phase}.json"
    if not result_path.is_file():
        raise RuntimeError(f"No checked result for {phase}.\n{process.stdout}\n{process.stderr}")
    result = json.loads(result_path.read_text())
    if result.get("phase") != phase:
        raise RuntimeError(f"The worker reported the wrong phase for {phase}.")
    if phase == "limited" and arguments.trace:
        observed = {
            "workspaceWal": 0, "attachmentStaging": 0, "directProbe": 0,
        }
        for traced_process in trace.parent.glob(f"{trace.name}.*"):
            with traced_process.open(encoding="utf-8") as output:
                for line in output:
                    if "EFBIG" not in line:
                        continue
                    observed["workspaceWal"] += "/sqlite/workspace.sqlite3-wal>" in line
                    observed["attachmentStaging"] += "/attachments/.easy-stage-imports-" in line
                    observed["directProbe"] += "/ceiling-probe>" in line
        if not all(observed.values()):
            raise RuntimeError(f"The syscall trace did not show each kernel rejection: {observed}.")
        result["kernelRejectedWrites"] = observed
    return result


def rejected_permissions(arguments, fixture):
    workspace = fixture / "sqlite" / "workspace.sqlite3"
    if any(workspace.with_name(workspace.name + suffix).exists() for suffix in ("-wal", "-shm")):
        raise RuntimeError("Expected both SQLite connections to close before the permission test.")
    modes = {workspace: 0o400, workspace.parent: 0o500, fixture / "attachments": 0o500}
    original = {}
    digest = sha256(workspace.read_bytes()).hexdigest()
    try:
        for path, mode in modes.items():
            metadata = path.lstat()
            if (stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid() or
                    not path.resolve().is_relative_to(fixture)):
                raise RuntimeError("Expected an owner-controlled fixture path.")
            original[path] = stat.S_IMODE(metadata.st_mode)
            path.chmod(mode)
        result = run_phase(arguments, fixture, "read-only")
        if sha256(workspace.read_bytes()).hexdigest() != digest:
            raise RuntimeError("The read-only database file was altered.")
        return {**result, "databaseBytesUnchanged": True}
    finally:
        for path, mode in reversed(tuple(original.items())):
            path.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default=os.environ.get("FLUTTER_BIN", "flutter"))
    parser.add_argument("--trace", metavar="STRACE", help="verify the exact failed write syscalls")
    parser.add_argument("--report", type=Path, help="write a new JSON report")
    arguments = parser.parse_args()
    if platform.system() != "Linux" or os.getuid() == 0:
        parser.error("run this fixture as an unprivileged Linux user")

    with tempfile.TemporaryDirectory(prefix="easy-storage-capacity-") as temporary:
        fixture = Path(temporary).resolve() / "fixture"
        fixture.mkdir(mode=0o700)
        results = []
        max_bytes = 0
        for phase in PHASES:
            result = (rejected_permissions(arguments, fixture) if phase == "read-only"
                      else run_phase(arguments, fixture, phase))
            results.append(result)
            max_bytes = max(max_bytes, sum(
                file.stat().st_size for file in fixture.rglob("*") if file.is_file()
            ))
            if max_bytes > 2 * 1024 * 1024:
                raise RuntimeError("The disposable fixture exceeded its storage budget.")
            print(f"{phase}: revision {result['revision']}, integrity {result['integrity']}", flush=True)

        if [result["revision"] for result in results] != [2, 2, 2, 3, 3]:
            raise RuntimeError("The failed writes or replay changed the saved revision.")
        for group in (results[:3], results[3:]):
            if any(result["workspaceDigest"] != group[0]["workspaceDigest"] or
                   result["attachmentDigests"] != group[0]["attachmentDigests"] for result in group):
                raise RuntimeError("The acknowledged records changed across a process restart.")
        payload = json.dumps({
            "version": 1, "architecture": platform.machine(), "kernel": platform.release(),
            "maximumFixtureBytesBetweenPhases": max_bytes, "phases": results,
        }, indent=2) + "\n"
        if arguments.report:
            with arguments.report.open("x", encoding="utf-8") as output:
                output.write(payload)
        else:
            print(payload, end="")


if __name__ == "__main__":
    main()
