#!/usr/bin/env bash
set -euo pipefail

flutter_bin=${FLUTTER_BIN:-flutter}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/easy-storage-crash.XXXXXXXX")
worker=tool/benchmark/storage_crash_worker_test.dart
launcher=''

cleanup() {
  if [[ -n $launcher ]] && kill -0 "$launcher" 2>/dev/null; then
    kill -TERM "$launcher" 2>/dev/null || true
    wait "$launcher" 2>/dev/null || true
  fi
  rm -rf -- "$fixture"
}
trap cleanup EXIT

EASY_CRASH_FIXTURE="$fixture" EASY_CRASH_PHASE=write \
  "$flutter_bin" test --no-pub "$worker" --reporter expanded >"$fixture/writer.log" 2>&1 &
launcher=$!

if ! python3 - "$fixture" <<'PYTHON'
import os
import signal
import sqlite3
import sys
import time
from pathlib import Path

fixture = Path(sys.argv[1])
deadline = time.monotonic() + 60
test_pid = None
while time.monotonic() < deadline:
    try:
        test_pid = int((fixture / "writer.pid").read_text())
        if Path(os.readlink(f"/proc/{test_pid}/exe")).name != "flutter_tester":
            raise SystemExit("The fixture worker is not Flutter's test process")
        break
    except (FileNotFoundError, ValueError):
        time.sleep(0.01)
else:
    raise SystemExit("The synthetic writer did not start")

database = sqlite3.connect(fixture / "workspace.sqlite3", timeout=0)
try:
    while time.monotonic() < deadline:
        try:
            database.execute("BEGIN IMMEDIATE")
            database.rollback()
        except sqlite3.OperationalError as error:
            if error.sqlite_errorcode != sqlite3.SQLITE_BUSY:
                raise
            os.kill(test_pid, signal.SIGKILL)
            print("Stopped the synthetic Flutter process while SQLite held a write lock")
            break
        time.sleep(0.001)
    else:
        raise SystemExit("The synthetic writer did not reach its transaction")
finally:
    database.close()
PYTHON
then
  cat "$fixture/writer.log"
  exit 1
fi

if wait "$launcher"; then
  cat "$fixture/writer.log"
  exit 1
fi
launcher=''

EASY_CRASH_FIXTURE="$fixture" EASY_CRASH_PHASE=verify \
  "$flutter_bin" test --no-pub "$worker" --reporter expanded
