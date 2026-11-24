#!/usr/bin/env python3
"""Review a manual Local estimate and an observed median in a disposable Linux app."""

import argparse
from contextlib import ExitStack
from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
import shutil
import tempfile
import threading

from local_inference import sha256
from native_local_ai_lifecycle import (
    BUTTON_FILL, HEIGHT, WIDTH, MODEL, TASK, LoopbackFixture, ai_state, capture_screen, click,
    confirm_dialog, launch_app, open_settings, read_workspace, save_settings,
    scroll_to, setup_profile, type_field,
)
from native_ui_soak import workspace_state
from native_voice_capture import command, until


HISTORY_TITLE = "Count silver sample boxes"
HISTORY_TASK = "timed-boxes"
HISTORY_MINUTES = (28, 34, 41)
REQUEST_FIELDS = ["captureId", "contextRevision", "sourceRevision", "title"]


def seed_history(profile):
    preferences = profile.parent / "shared_preferences.json"
    values = json.loads(preferences.read_text())
    workspace = json.loads(values["easy.workspace.v1"])
    workspace["tasks"].append({
        "id": HISTORY_TASK, "title": HISTORY_TITLE, "category": "work",
        "date": date.today().isoformat(), "done": False,
    })
    records = []
    for index, minutes in enumerate(HISTORY_MINUTES):
        task_id = f"past-boxes-{index}"
        start = datetime.now(timezone.utc) - timedelta(days=index + 2)
        end = start + timedelta(minutes=minutes)
        workspace["tasks"].append({
            "id": task_id, "title": HISTORY_TITLE, "category": "work",
            "done": True, "completedAt": end.isoformat(),
        })
        records.append({
            "id": f"timer-{task_id}", "title": HISTORY_TITLE, "category": "work",
            "target": {"id": task_id, "title": HISTORY_TITLE, "category": "work", "kind": "task"},
            "spans": [{"start": start.isoformat(), "end": end.isoformat()}],
            "steps": [], "checkedStepIds": [], "finishedAt": end.isoformat(), "timeSource": "timer",
        })
    workspace["activities"] = {"version": 1, "records": records, "routines": []}
    values["easy.workspace.v1"] = json.dumps(workspace)
    preferences.write_text(json.dumps(values))


def dialog_text(screen):
    with capture_screen(screen) as image:
        rows = [y for y in range(HEIGHT) if min(image.getpixel((WIDTH // 2, y))) >= 205]
        if not rows or rows[-1] >= HEIGHT - 5:
            return ""
        center = rows[len(rows) // 2]
        columns = [x for x in range(WIDTH) if min(image.getpixel((x, center))) >= 205]
        if not columns:
            return ""
        crop = image.crop((columns[0], rows[0], columns[-1] + 1, rows[-1] + 1))
        path = screen.path.with_name("review-dialog.png")
        crop.resize((crop.width * 3, crop.height * 3)).save(path)
    text = command(screen.env, screen.args.tesseract, path, "stdout", "--psm", 6)
    return " ".join(text.lower().split())


def use_median(screen):
    until(lambda: "use median estimate" in dialog_text(screen), "the explicit median review action")
    with capture_screen(screen) as image:
        bottom = max(y for y in range(HEIGHT) if min(image.getpixel((WIDTH // 2, y))) >= 205)
        y = bottom - 42
        right = max(x for x in range(WIDTH // 2, WIDTH) if image.getpixel((x, y)) == BUTTON_FILL)
    click(screen, right - 36, y)


def run(args, stage, evidence):
    env, profile = setup_profile(stage)
    seed_history(profile)
    database = profile / "workspace.sqlite3"
    ai_database = profile / "ai-device.sqlite3"

    def saved_minutes(task_id):
        return next(task for task in read_workspace(database)["tasks"]
                    if task["id"] == task_id).get("estimatedMinutes")

    with LoopbackFixture() as runtime, ExitStack() as stack:
        thread = threading.Thread(target=runtime.serve_forever, daemon=True)
        thread.start()
        stack.callback(thread.join, 3)
        stack.callback(runtime.shutdown)
        screen = launch_app(args, stack, stage, env)
        evidence["step"] = "enable manual Local estimates"
        open_settings(screen)
        scroll_to(screen, "monthly limit")
        until(lambda: screen.find("Offline"), "the AI route controls")
        click(screen, 471, 89)
        address = f"http://127.0.0.1:{runtime.server_port}/v1"
        type_field(screen, "Base URL", address)
        type_field(screen, "Model", MODEL)
        scroll_to(screen, "Suggest durations")
        save_settings(screen)
        settings = until(lambda: ai_state(ai_database).get("settings"), "the device AI settings")
        assert settings["route"] == "local" and settings["localBaseUrl"] == address
        assert settings["allowEstimates"] and settings["confirmLocal"]
        assert not settings["automaticEstimates"] and not settings["includeOptionalMetadata"]

        click(screen, 27, 28)
        until(lambda: screen.find("Settings"), "the workspace Settings page")
        click(screen, 346, 42)
        until(lambda: screen.find("All spaces"), "the foreground workspace")
        screen.tap(TASK)
        evidence["step"] = "review point estimate"
        screen.tap("Suggest duration")
        confirm_dialog(screen, "local runtime", cancel=True)
        until(lambda: screen.find("Suggest duration"), "the task after declining transmission")
        assert not runtime.requests and saved_minutes("local-fixture-task") is None
        evidence["declined_no_request"] = True

        screen.tap("Suggest duration")
        confirm_dialog(screen, "local runtime")
        until(lambda: "task title only" in dialog_text(screen), "the title-only provenance")
        until(lambda: "35 min" in dialog_text(screen), "the proposed point estimate")
        assert saved_minutes("local-fixture-task") is None
        assert len(runtime.requests) == 1
        point = runtime.requests[0]
        assert point["kind"] == "estimate" and point["fields"] == REQUEST_FIELDS
        assert point["expected_input"] and point["model_matched"] and not point["api_credential"]
        confirm_dialog(screen, "duration estimate")
        until(lambda: saved_minutes("local-fixture-task") == 35, "the saved point estimate")

        evidence["step"] = "review comparable timing history"
        screen.tap(HISTORY_TITLE)
        screen.tap("Timing history")
        until(lambda: "34 min median" in dialog_text(screen), "the median of the three observed timers")
        until(lambda: "28 min to 41 min" in dialog_text(screen), "the observed elapsed range")
        assert saved_minutes(HISTORY_TASK) is None and len(runtime.requests) == 1
        use_median(screen)
        until(lambda: saved_minutes(HISTORY_TASK) == 34, "the saved local median")

        final = workspace_state(database)
        assert final["quick_check"] == "ok" and len(runtime.requests) == 1
        assert final["counts"]["tasks"] == 5
        evidence.update(status="passed", request=point, point_minutes=35,
                        evidence_minutes=list(HISTORY_MINUTES), median_minutes=34,
                        total_provider_requests=1, workspace=final)
        evidence.pop("step")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--failure-image", type=Path)
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--window-manager", default="xfwm4")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--x11-capture", default="import")
    parser.add_argument("--tesseract", default="tesseract")
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    evidence = {
        "status": "interrupted", "app_revision": args.app_revision,
        "run_at_utc": datetime.now(timezone.utc).isoformat(),
        "executable_sha256": sha256(args.binary),
        "aot_library_sha256": sha256(args.binary.parent / "lib" / "libapp.so"),
    }
    with tempfile.TemporaryDirectory(prefix="easy-local-estimate-") as directory:
        stage = Path(directory)
        try:
            run(args, stage, evidence)
        finally:
            if args.failure_image and evidence["status"] != "passed" and (stage / "screen.png").is_file():
                shutil.copyfile(stage / "screen.png", args.failure_image)
            args.output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
