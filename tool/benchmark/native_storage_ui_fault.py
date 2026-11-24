#!/usr/bin/env python3
"""Exercise the Linux task inspector under an actual per-file write limit."""

import argparse
from contextlib import ExitStack, closing
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import resource
import runpy
import selectors
import sqlite3
import subprocess
import tempfile
import time

from native_ui_soak import wait_for_workspace, workspace_state


ROOT = Path(__file__).resolve().parents[2]
SIZE = (1280, 720)
TITLE = "Confirm studio allocation"


def profile_fixture(environment):
    profile = Path(environment["XDG_DATA_HOME"]) / "app.launchsites.easy"
    profile.mkdir(mode=0o700)
    day = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    task = {
        "id": "storage-fault-task",
        "title": TITLE,
        "category": "work",
        "date": day.replace(tzinfo=None).isoformat(timespec="milliseconds"),
        "done": False,
        "estimatedMinutes": 30,
        "dueAt": day.replace(hour=17, minute=35).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "notes": "Get the latest floor plan from the venue before the deadline.",
    }
    note = {
        "id": "storage-fault-note",
        "title": "A previously saved note",
        "body": "Synthetic note retained during the write fault.",
        "updated": task["date"],
    }
    workspace = {"events": [], "tasks": [task], "notes": [note]}
    (profile / "shared_preferences.json").write_text(
        json.dumps({"easy.workspace.v1": json.dumps(workspace)}), encoding="utf-8",
    )
    return profile / "easy" / "workspace.sqlite3"


def failure_visible(screen, stage):
    screenshot = stage / "save-error.png"
    strip = stage / "status.png"
    deadline = time.monotonic() + 15
    observed = False
    samples = 0
    while time.monotonic() < deadline:
        subprocess.run(
            [screen.args.capture, "-window", screen.identifier, "-strip", str(screenshot)],
            env=screen.env, capture_output=True, check=True, timeout=8,
        )
        subprocess.run(
            ["convert", str(screenshot), "-crop", "1280x150+0+570", "+repage", str(strip)],
            env=screen.env, capture_output=True, check=True, timeout=5,
        )
        text = " ".join(screen.ocr(strip, "txt").casefold().split())
        samples += 1
        if "task completed" in text:
            raise RuntimeError("The inspector acknowledged the rejected write.")
        if "could not be saved on this device" in text and not observed:
            observed = True
            deadline = time.monotonic() + 1
        time.sleep(0.15)
    if not observed:
        raise RuntimeError("The inspector did not show a save error.")
    return samples


def select_inspector(screen, stage):
    screen.tap(75, 195)
    tasks = screen.capture("tasks", SIZE, (TITLE.casefold(), "completed"))
    screen.tap_word(tasks, "Confirm")
    shown = screen.capture("inspector", SIZE, ("track time",))
    right = stage / "inspector-actions.png"
    left = 972
    subprocess.run(
        ["convert", str(shown), "-crop", f"308x720+{left}+0", "+repage", str(right)],
        env=screen.env, capture_output=True, check=True, timeout=5,
    )
    for item in screen.ocr(right, "tsv").splitlines()[1:]:
        columns = item.split("\t")
        if len(columns) == 12 and columns[-1].casefold() == "mark":
            x, y, width, height = map(int, columns[6:10])
            return left + x + width // 2, y + height // 2
    raise RuntimeError("Could not locate Mark done in the task inspector.")


def saved_revision(path, revision):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        saved = workspace_state(path, include_document=True)
        if saved["revision"] == revision:
            return saved
        if saved["revision"] > revision:
            raise RuntimeError("The retry produced more than one workspace write.")
        time.sleep(0.15)
    raise RuntimeError("The successful retry did not produce the expected revision.")


def verify(arguments, stage):
    renderer = runpy.run_path(str(ROOT / "tool/appearance_review/render.py"))
    environment = renderer["isolated_environment"](stage, arguments)
    environment.update({"LP_NUM_THREADS": "2", "GALLIUM_DRIVER": "llvmpipe", "TZ": "UTC"})
    database = profile_fixture(environment)
    with ExitStack() as close:
        xlog = close.enter_context((stage / "xvfb.log").open("wb"))
        display = subprocess.Popen(
            [arguments.xvfb, "-displayfd", "1", "-screen", "0", "1400x850x24",
             "-nolisten", "tcp", "-ac", "-noreset"],
            stdout=subprocess.PIPE, stderr=xlog, env=environment, text=True,
        )
        close.callback(renderer["stop"], display)
        with selectors.DefaultSelector() as ready:
            ready.register(display.stdout, selectors.EVENT_READ)
            if not ready.select(timeout=12):
                raise RuntimeError("The isolated X11 display did not start.")
            environment["DISPLAY"] = ":" + display.stdout.readline().strip()

        def launch(label):
            log = close.enter_context((stage / f"{label}.log").open("wb"))
            application = subprocess.Popen(
                ["bash", "-c", "trap '' XFSZ; exec \"$1\"", "easy-storage-limit", str(arguments.app)],
                env=environment, stdout=log, stderr=log,
            )
            close.callback(renderer["stop"], application)
            window = renderer["live_window"](application.pid, environment, arguments.xdotool)
            screen = renderer["NativeWindow"](window, environment, arguments, stage)
            screen.send("windowmove", window, 0, 0)
            screen.send("windowfocus", window)
            screen.capture(f"{label}-ready", SIZE, ("today",))
            wait_for_workspace(database)
            return application, screen

        application, screen = launch("initial")
        position = select_inspector(screen, stage)
        prior = workspace_state(database, include_document=True)
        if prior["document"]["tasks"][0]["done"] or prior["quick_check"] != "ok":
            raise RuntimeError("The initial task and database state must be healthy.")
        soft_limit = resource.prlimit(application.pid, resource.RLIMIT_FSIZE)
        wal_path = database.with_name(database.name + "-wal")

        # The live read pins the frames so SQLite must append to commit.
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as reader:
            reader.execute("BEGIN")
            reader.execute("SELECT revision FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
            ceiling = wal_path.stat().st_size
            if not 0 < ceiling < 2 * 1024 * 1024:
                raise RuntimeError("The synthetic WAL size is outside its fixture range.")
            resource.prlimit(application.pid, resource.RLIMIT_FSIZE, (ceiling, soft_limit[1]))
            try:
                screen.tap(*position)
                fault_samples = failure_visible(screen, stage)
                rejected = workspace_state(database, include_document=True)
                if rejected != prior or wal_path.stat().st_size != ceiling:
                    raise RuntimeError("The failed inspector action changed the saved workspace.")
            finally:
                if application.poll() is None:
                    resource.prlimit(application.pid, resource.RLIMIT_FSIZE, soft_limit)

        screen.tap(*position)
        saved = saved_revision(database, prior["revision"] + 1)
        task = dict(saved["document"]["tasks"][0])
        if not task.pop("done") or not task.pop("completedAt"):
            raise RuntimeError("The reopened file limit did not permit task completion.")
        restored_document = {**saved["document"], "tasks": [{**task, "done": False}]}
        if restored_document != prior["document"]:
            changed = [
                key for key in restored_document.keys() | prior["document"].keys()
                if restored_document.get(key) != prior["document"].get(key)
            ]
            raise RuntimeError(f"The successful retry changed existing records: {changed}.")
        screen.capture("committed", SIZE, ("reopen",))
        renderer["stop"](application)
        launch("reopened")
        reopened = workspace_state(database, include_document=True)
        if reopened != saved or reopened["quick_check"] != "ok":
            raise RuntimeError("The successful write did not survive a native restart.")

        return {
            "file_size_ceiling_bytes": ceiling,
            "fault_status_frames_sampled": fault_samples,
            "error_observed_before_success": True,
            "fixture_task_kept_open_while_faulted": True,
            "before": {key: value for key, value in prior.items() if key != "document"},
            "rejected": {key: value for key, value in rejected.items() if key != "document"},
            "retried": {key: value for key, value in saved.items() if key != "document"},
            "reopened": {key: value for key, value in reopened.items() if key != "document"},
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--verification", type=Path, required=True, help="the release bundle's hash report")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--extra-libraries", type=Path)
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--capture", default="import")
    parser.add_argument("--identify", default="identify")
    parser.add_argument("--ocr", default="tesseract")
    arguments = parser.parse_args()
    arguments.app = arguments.app.resolve()
    released = json.loads(arguments.verification.read_text())
    binary = sha256(arguments.app.read_bytes()).hexdigest()
    aot = sha256((arguments.app.parent / "lib" / "libapp.so").read_bytes()).hexdigest()
    if binary != released["executable_sha256"] or aot != released["aot_library_sha256"]:
        raise RuntimeError("The release bundle did not match its verification report.")

    with tempfile.TemporaryDirectory(prefix="easy-native-commit-fault-") as temporary:
        report = {
            "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
            "app_revision": released["app_revision"],
            "executable_sha256": binary, "aot_library_sha256": aot,
            **verify(arguments, Path(temporary)),
        }
    payload = json.dumps(report, indent=2) + "\n"
    if arguments.report:
        with arguments.report.open("x", encoding="utf-8") as output:
            output.write(payload)
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()
