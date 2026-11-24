#!/usr/bin/env python3
"""Check a Linux AOT bundle in a disposable Easy workspace and X11 display."""

import argparse
from contextlib import ExitStack, closing
from datetime import date, datetime, time, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import sqlite3
import subprocess
import tempfile
import time as clock

from local_inference import sha256
from native_ui_fixture import workspace
from native_ui_soak import (
    PAGES, check_desktop_route, check_heading, chunked_document, visible_window, workspace_state,
)
from native_voice_capture import Screen, command, start_child, until
from native_workspace_scale import stop


WIDE = (1280, 900)
PHONE = (390, 844)
TASK = "Order saffron folders"
INITIAL_TASK = "File copper receipts"
CURRENT_EVENT = "Tangerine booking"
NEXT_EVENT = "Jasmine appointment"
LIVE_WORKOUT = "Upper body fixture"
WORKOUT_TASK = "Write session handoff"
WORKOUT_STRETCH = "After treadmill, I stretched"
WORKOUT_BENCH = "I did bench press 60kg x8,8,6"
WORKOUT_CAPTURE = f"Work: task: {WORKOUT_TASK}; {WORKOUT_STRETCH}; {WORKOUT_BENCH}"


def initial_profile(profile, *, live_workout=False):
    profile.mkdir()
    today = date.today()
    state = workspace(today, 0, 0, 1)
    for offset, title in enumerate((CURRENT_EVENT, NEXT_EVENT)):
        begin = datetime.combine(today + timedelta(days=offset), time())
        state["events"].append({
            "id": f"smoke-{offset}", "title": title, "category": "personal",
            "start": begin.isoformat(),
            "end": (begin + timedelta(days=1)).isoformat(), "allDay": True,
        })
    state["tasks"].append({
        "id": "smoke-task", "title": INITIAL_TASK, "category": "work",
        "date": today.isoformat(), "done": False,
    })
    state["health"] = {
        "version": 1, "goals": [], "limitations": [], "decisions": [],
        "measurements": [
            {
                "id": "smoke-weigh-in-1", "kind": "bodyWeight", "unit": "pounds",
                "value": 160, "recordedAt": datetime.combine(today - timedelta(days=8), time(8), timezone.utc).isoformat(),
            },
            {
                "id": "smoke-weigh-in-2", "kind": "bodyWeight", "unit": "kilograms",
                "value": 73, "recordedAt": datetime.combine(today - timedelta(days=3), time(8), timezone.utc).isoformat(),
            },
        ],
    }
    sessions = []
    for days_ago, kg, reps in ((8, 50, 8), (3, 60, 6)):
        at = datetime.combine(today - timedelta(days=days_ago), time(17))
        exercise = {
            "id": "smoke-bench", "name": "Bench press", "kind": "strength",
            "sets": [{"id": "smoke-set", "weightKg": kg, "reps": reps}],
        }
        sessions.append(json.dumps({
            "planned": True, "planId": "smoke-strength", "planName": "Strength session",
            "startedAt": at.isoformat(),
            "finishedAt": (at + timedelta(minutes=30)).isoformat(),
            "exercises": [exercise], "entries": [],
            "progress": {json.dumps(["smoke-bench", "smoke-set"], separators=(",", ":")): "done"},
        }))
    if live_workout:
        exercises = [
            {"id": "treadmill", "name": "Treadmill", "kind": "cardio",
             "distanceKm": 0.5, "inclinePercent": 2, "minutes": 5},
            {
                "id": "bench", "name": "Bench press", "kind": "strength",
                "sets": [
                    {"id": item, "weightKg": 50, "reps": 8}
                    for item in ("first", "second", "third")
                ],
            },
        ]
        sessions.append(json.dumps({
            "planned": True, "planId": "live-fixture", "planName": LIVE_WORKOUT,
            "startedAt": (datetime.now() - timedelta(minutes=3)).isoformat(),
            "exercises": exercises, "plannedExercises": exercises, "entries": [],
        }))
    (profile / "shared_preferences.json").write_text(json.dumps({
        "easy.workspace.v1": json.dumps(state),
        "easy.gym-sessions.v1": sessions,
    }))


def get_window(args, env, app):
    try:
        window, pid = visible_window(args.xdotool, env=env)
    except subprocess.CalledProcessError:
        return None
    if pid != app.pid:
        raise RuntimeError("The window does not belong to the disposable app process.")
    return window


def stored_workspace(database):
    try:
        return workspace_state(database, include_document=True)
    except (sqlite3.OperationalError, FileNotFoundError):
        return None


def workout_documents(database):
    location = f"{database.resolve().as_uri()}?mode=ro"
    with closing(sqlite3.connect(location, uri=True, timeout=3)) as db:
        sessions, plans = db.execute("""
            SELECT gym_sessions, workout_plans
            FROM revisions ORDER BY revision DESC LIMIT 1
        """).fetchone()
        result = {}
        for key, digest in (("gym_sessions", sessions), ("workout_plans", plans)):
            body, chunked = db.execute(
                "SELECT body, chunked FROM documents WHERE digest = ?", (digest,),
            ).fetchone()
            records = json.loads(chunked_document(db, digest) if chunked else body)
            result[key] = [json.loads(record) for record in records]
        return result


def new_profile(parent, environment):
    parent.mkdir(mode=0o700)
    env = environment.copy()
    for name in ("DATA", "CONFIG", "CACHE", "RUNTIME"):
        location = parent / name.lower()
        location.mkdir(mode=0o700)
        env["XDG_RUNTIME_DIR" if name == "RUNTIME" else f"XDG_{name}_HOME"] = str(location)
    return env, parent / "data" / "app.launchsites.easy"


def setup_state(database, *, samples):
    state = stored_workspace(database)
    if state is None or state["document"].get("workspaceSetup") != "complete":
        return None
    document = state.pop("document")
    features = set(document["features"]["enabled"])
    counts = {"events": 6, "tasks": 8, "notes": 5} if samples else dict.fromkeys(("events", "tasks", "notes"), 0)
    if state["counts"] != counts or state["quick_check"] != "ok":
        raise RuntimeError(f"Workspace setup produced unexpected counts or database status: {state['counts']}.")
    if (samples and not {"workouts", "health", "ai"}.issubset(features)) or (not samples and features):
        raise RuntimeError("Workspace setup saved an unexpected feature selection.")
    for kind in counts:
        ids = {record["id"] for record in document[kind]}
        if len(ids) != counts[kind] or (samples and not all(record.startswith("sample-") for record in ids)):
            raise RuntimeError(f"Expected each sample {kind} record exactly once.")
    workouts = workout_documents(database)
    expected = ["sample-upper-body"] if samples else []
    actual = [plan["id"] for plan in workouts["workout_plans"]]
    if actual != expected or workouts["gym_sessions"]:
        raise RuntimeError("Workspace setup saved unexpected workout plans or session records.")
    return {**state, "enabled_features": sorted(features), "workout_plan_ids": actual}


def resize(screen, dimensions):
    screen.send("windowsize", "--sync", screen.window, *dimensions)


def click_at(screen, x, y):
    screen.move(x, y)
    screen.send("click", 1)


def choose_orbit(screen, end_x, end_y):
    _, h = PHONE
    screen.send(
        "mousemove", "--window", screen.window, 48, h - 48, "mousedown", 1,
        "sleep", 0.7, "mousemove", "--window", screen.window, end_x, end_y,
        "sleep", 0.2, "mouseup", 1,
    )


def swipe_next_day(screen):
    screen.send("mousemove", "--window", screen.window, 320, 290, "mousedown", 1)
    for x in (292, 262, 215, 160, 100, 64):
        screen.move(x, 290)
        clock.sleep(0.025)
    screen.send("mouseup", 1)


def open_gym(screen):
    choose_orbit(screen, 52, PHONE[1] - 170)
    until(lambda: screen.find("Note to self"), "Today after the orbit gesture")
    clock.sleep(0.25)
    for attempt in range(2):
        click_at(screen, 323, 44)
        try:
            gym = until(lambda: screen.find("Gym"), "Gym in the focus menu", seconds=4)
        except RuntimeError:
            if attempt == 0:
                continue
            raise
        click_at(screen, *gym)
        return


def run(args, stage, report):
    env = dict(os.environ, GDK_BACKEND="x11", LIBGL_ALWAYS_SOFTWARE="1",
               GSETTINGS_BACKEND="memory", OMP_THREAD_LIMIT="1")
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    env, profile = new_profile(stage / "seeded", env)
    initial_profile(profile)
    database = profile / "easy" / "workspace.sqlite3"

    with ExitStack() as stack:
        display = start_child(
            stack, env, stage / "xvfb.log", args.xvfb, "-displayfd", "1",
            "-screen", "0", "1440x1000x24", "-nolisten", "tcp", "-noreset", "-ac", pipe=True,
        )
        with selectors.DefaultSelector() as selector:
            selector.register(display.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=8):
                raise RuntimeError("The disposable display did not start.")
            env["DISPLAY"] = f":{int(display.stdout.readline())}"
        old_display = os.environ.get("DISPLAY")
        os.environ["DISPLAY"] = env["DISPLAY"]
        stack.callback(_restore_display, old_display)

        def open_app(name, environment=env):
            app = start_child(stack, environment, stage / f"{name}.log", args.binary)
            window = until(lambda: get_window(args, environment, app), "the disposable app window")
            screen = Screen(args, stage, environment, window)
            screen.send("windowfocus", window)
            return app, screen

        def check(name, label, crop=None):
            report["current_step"] = name
            if crop:
                def cropped_label():
                    return check_heading(
                        screen.window, stage, re.escape(label), crop, args.x11_capture, args.tesseract,
                    )["matched"]
                until(cropped_label, f"{label!r} on {name}", seconds=args.timeout)
                command(screen.env, args.x11_capture, "-window", screen.window, screen.path)
            else:
                until(lambda: screen.find(label), f"{label!r} on {name}", seconds=args.timeout)
            report["checks"][name] = {"screenshot_sha256": sha256(screen.path)}
            if args.screenshots:
                shutil.copyfile(screen.path, args.screenshots / f"{name}.png")

        app, screen = open_app("first")
        resize(screen, WIDE)
        report["before"] = until(lambda: stored_workspace(database), "workspace migration")
        # The fixed desktop nav positions are shared with the route soak.
        for name, y, heading in PAGES:
            report["current_step"] = f"desktop-{name.lower()}"
            click_at(screen, 76, y)
            screen.move(1256, 49)
            checked = check_desktop_route(screen.window, stage, y, heading, args)
            if not checked["selected"]:
                raise RuntimeError(f"The desktop {name} destination did not become selected.")
            check(f"desktop-{name.lower()}", {
                "Today": CURRENT_EVENT, "Calendar": CURRENT_EVENT,
                "Tasks": INITIAL_TASK, "Notes": "Synthetic reading note",
            }[name])

        click_at(screen, 76, PAGES[2][1])
        click_at(screen, WIDE[0] - 68, 35)
        check("desktop-task-capture", "needs doing", "520x124+378+388")
        screen.send("type", "--delay", 2, TASK)
        screen.send("key", "Return")
        until(lambda: _has_task(database), "the captured task in SQLite")
        check("desktop-task-saved", TASK)

        click_at(screen, 76, PAGES[3][1])
        screen.send("key", "ctrl+k")
        check("desktop-search", "Search workspace", "615x145+333+189")
        screen.send("type", "--delay", 2, "saffron")
        check("desktop-search-result", TASK, "615x430+332+189")
        screen.send("key", "Escape")

        resize(screen, PHONE)
        clock.sleep(0.35)
        choose_orbit(screen, 108, PHONE[1] - 151)
        check("mobile-orbit-calendar", CURRENT_EVENT)
        swipe_next_day(screen)
        check("mobile-calendar-next-day", NEXT_EVENT)

        open_gym(screen)
        check("mobile-gym", "Freestyle")
        screen.tap("History")
        check("mobile-gym-history", "Workout history")
        if args.gym_progress:
            screen.tap("Progress")
            check("mobile-gym-progress", "Latest 60 kg")
            resize(screen, (320, 568))
            check("compact-gym-progress", "Latest 60 kg")
            resize(screen, PHONE)
            clock.sleep(0.35)
        if args.health_scope:
            click_at(screen, 92, 129)
            check("mobile-gym-record-picker", "Choose a record")
            screen.tap("Body weight")
            check("mobile-gym-measured-weight", "Latest 73 kg")
        click_at(screen, 28, 28)
        check("mobile-gym-return", "Freestyle")
        screen.tap("Mode")
        screen.tap("Settings")
        check("mobile-settings", "Focus modes")
        screen.tap("Features")
        check("mobile-feature-privacy", "Health notes")
        if args.health_scope:
            screen.tap("Health notes")
            until(lambda: _kept_health_disabled(database), "the saved health visibility preference")

        stop(app)
        app, screen = open_app("reopened")
        resize(screen, WIDE)
        check("reopened-workspace", CURRENT_EVENT)
        click_at(screen, 76, PAGES[2][1])
        check("reopened-task", TASK)
        report["after"] = until(lambda: stored_workspace(database), "the reopened workspace")
        if not _has_task(database) or report["after"]["quick_check"] != "ok":
            raise RuntimeError("Reopening did not preserve a healthy workspace and its captured task.")
        if args.health_scope:
            report["current_step"] = "reopened-gym-health-scope"
            resize(screen, PHONE)
            clock.sleep(0.35)
            open_gym(screen)
            screen.tap("History")
            check("reopened-gym-history", "Workout history")
            screen.tap("Progress")
            check("reopened-gym-progress", "Latest 60 kg")
            click_at(screen, 92, 129)
            clock.sleep(0.45)
            if screen.find("Choose a record") or not _kept_health_disabled(database):
                raise RuntimeError("Gym exposed body weight with the Health notes feature disabled.")
            report["health_measurements_hidden_and_retained"] = True
        stop(app)

        if args.onboarding:
            report["onboarding"] = {}
            for option, size, home_probe in (
                ("skip", PHONE, "No tasks due today"),
                ("samples", WIDE, "Send the project outline"),
            ):
                is_samples = option == "samples"
                blank_env, blank_profile = new_profile(stage / option, env)
                blank_db = blank_profile / "easy" / "workspace.sqlite3"
                app, screen = open_app(option, blank_env)
                resize(screen, size)
                check(f"onboarding-{option}-blank", "Set up Easy",
                      crop="540x135+370+203" if is_samples else None)
                if is_samples:
                    click_at(screen, 443, 556)
                    click_at(screen, 660, 648)
                else:
                    screen.tap("Skip")
                check(f"onboarding-{option}-today", home_probe)
                before = until(lambda: setup_state(blank_db, samples=is_samples), f"the {option} profile setup commit")
                stop(app)
                app, screen = open_app(f"{option}-reopened", blank_env)
                resize(screen, size)
                check(f"onboarding-{option}-reopened", home_probe)
                after = until(lambda: setup_state(blank_db, samples=is_samples), f"the reopened {option} profile")
                if before != after or screen.find("Set up Easy"):
                    raise RuntimeError(f"The {option} profile setup was not stable across reopening.")
                report["onboarding"][option] = {"before": before, "after": after}
                stop(app)

        if args.live_gym_capture:
            live_env, live_profile = new_profile(stage / "live-gym", env)
            initial_profile(live_profile, live_workout=True)
            live_db = live_profile / "easy" / "workspace.sqlite3"
            app, screen = open_app("live-gym", live_env)
            resize(screen, PHONE)
            screen.tap("Mode")
            screen.tap("Gym")
            check("live-gym-resumable", LIVE_WORKOUT)
            resume_live_fixture(screen)
            check("live-gym-session", "Finish")
            before = until(lambda: stored_workspace(live_db), "the initial live workout")
            click_at(screen, PHONE[0] - 44, PHONE[1] - 38)
            check("live-gym-capture", "Capture review")
            screen.tap("Capture text")
            screen.send("type", "--delay", 2, WORKOUT_CAPTURE)
            screen.tap_footer()
            check("live-gym-completion-choice", "Mark these sets done")
            screen.tap("Mark these sets done")
            screen.tap_footer()
            screen.move(PHONE[0] - 6, 558)
            check("live-gym-capture-returns", "Finish")
            after = until(lambda: captured_workout_state(live_db), "the captured workout and task")
            if after["revision"] != before["revision"] + 2:
                raise RuntimeError("Expected one capture draft and one reviewed transaction.")
            reveal_record(screen, "Stretched")
            check("live-gym-refreshed", "Stretched")
            stop(app)

            app, screen = open_app("live-gym-reopened", live_env)
            resize(screen, PHONE)
            screen.tap("Mode")
            screen.tap("Gym")
            check("live-gym-reopened-resumable", LIVE_WORKOUT)
            resume_live_fixture(screen, last_pending="Treadmill")
            check("live-gym-reopened-session", "Finish")
            reveal_record(screen, "Stretched")
            check("live-gym-reopened-result", "Stretched")
            reopened = captured_workout_state(live_db)
            if after != reopened:
                raise RuntimeError("The reviewed result changed after reopening.")
            report["live_workout_capture"] = {"after": after, "reopened": reopened}
            stop(app)
        report.pop("current_step", None)


def resume_live_fixture(screen, last_pending="Bench press"):
    _, exercise_y = until(lambda: screen.find(last_pending), "the live workout preview")
    click_at(screen, 106, exercise_y + 48)
    screen.move(PHONE[0] - 6, 558)


def captured_workout_state(database):
    state = stored_workspace(database)
    if state is None:
        return None
    data = state.pop("document")
    tasks = [item for item in data["tasks"] if item["title"] == WORKOUT_TASK]
    if not tasks:
        return None
    captures = data.get("captures", [])
    sessions = workout_documents(database)["gym_sessions"]
    active = [item for item in sessions if item["planId"] == "live-fixture"]
    if (len(tasks) != 1 or tasks[0]["category"] != "work" or
            len(captures) != 1 or captures[0]["text"] != WORKOUT_CAPTURE or not captures[0]["applied"] or
            len(active) != 1 or
            state["quick_check"] != "ok" or active[0].get("finishedAt") is not None):
        raise RuntimeError("Capture altered the source, task category, workout identity, or database health.")
    active = active[0]
    actual = [(item["id"], item["weightKg"], item["reps"]) for item in active["exercises"][1]["sets"]]
    planned = [(item["id"], item["weightKg"], item["reps"]) for item in active["plannedExercises"][1]["sets"]]
    set_ids = ("first", "second", "third")
    done = {json.dumps(["bench", item], separators=(",", ":")): "done" for item in set_ids}
    cardio = active["exercises"][0]
    if (actual != list(zip(set_ids, (60, 60, 60), (8, 8, 6))) or
            planned != [(item, 50, 8) for item in set_ids] or active.get("progress") != done or
            (cardio["distanceKm"], cardio["inclinePercent"], cardio["minutes"]) != (0.5, 2, 5) or
            [entry["captureText"] for entry in active["entries"]] != [WORKOUT_STRETCH, WORKOUT_BENCH] or
            active["entries"][0]["afterExerciseId"] != "treadmill"):
        raise RuntimeError("The workout actuals, source text, completion, or planned sets changed unexpectedly.")
    return state


def reveal_record(screen, label):
    for _ in range(4):
        if screen.find(label):
            return
        screen.move(185, 550)
        screen.send("click", "--repeat", 4, 5)
        clock.sleep(0.25)
    until(lambda: screen.find(label), f"the reviewed {label!r} entry")


def _has_task(database):
    state = stored_workspace(database)
    return state is not None and any(task["title"] == TASK for task in state["document"]["tasks"])


def _kept_health_disabled(database):
    state = stored_workspace(database)
    if state is None:
        return False
    records = state["document"]
    return ("health" not in records.get("features", {}).get("enabled", ["health"])
            and len(records.get("health", {}).get("measurements", [])) == 2)


def _restore_display(display):
    if display is None:
        os.environ.pop("DISPLAY", None)
    else:
        os.environ["DISPLAY"] = display


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--screenshots", type=Path, help="optional directory for synthetic screenshots")
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--x11-capture", default="import")
    parser.add_argument("--tesseract", default="tesseract")
    parser.add_argument("--timeout", type=float, default=12, help="maximum seconds per screen check")
    parser.add_argument("--gym-progress", action="store_true", help="require the progress chart on builds that include it")
    parser.add_argument("--health-scope", action="store_true", help="verify health data is visible only while its feature is enabled")
    parser.add_argument("--onboarding", action="store_true", help="check Skip and Full with samples in independent blank profiles")
    parser.add_argument("--live-gym-capture", action="store_true", help="review live workout results and a cross-Focus task together")
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    app_library = args.binary.parent / "lib" / "libapp.so"
    if not app_library.is_file():
        parser.error("--binary must be from a Flutter Linux release bundle with lib/libapp.so")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.health_scope:
        args.gym_progress = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.screenshots:
        args.screenshots.mkdir(parents=True, exist_ok=True)
    report = {
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "app_revision": args.app_revision,
        "executable_sha256": sha256(args.binary),
        "aot_library_sha256": sha256(app_library),
        "status": "failed", "checks": {},
    }
    started = clock.monotonic()
    with tempfile.TemporaryDirectory(prefix="easy-release-smoke-") as directory:
        stage = Path(directory)
        try:
            run(args, stage, report)
            report["status"] = "passed"
        except (OSError, RuntimeError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
            report["failure"] = str(error)
            if args.screenshots and (stage / "screen.png").is_file():
                shutil.copyfile(stage / "screen.png", args.screenshots / "last-screen.png")
    for key in ("before", "after"):
        if key in report:
            report[key].pop("document")
    report["elapsed_seconds"] = round(clock.monotonic() - started, 2)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
