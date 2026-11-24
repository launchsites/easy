#!/usr/bin/env python3
"""Measure ready time for synthetic Linux workspaces in a disposable display."""

import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import selectors
import sqlite3
import subprocess
import tempfile
import time

from local_inference import host_details, sha256
from native_ui_fixture import workspace
from native_ui_soak import PAGES, check_desktop_route, visible_window, wait_for_workspace, workspace_state
from native_ui_trace import process_rss, send_input

PROFILES = (("standard", 7320, 3100, 1300), ("large", 30000, 100000, 3000))


def ready_window(args, app):
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline and app.poll() is None:
        try:
            return visible_window(args.xdotool)
        except subprocess.CalledProcessError:
            time.sleep(0.1)
    raise RuntimeError("The Easy window did not open.")


def run_variant(args, core, stage, label, events, tasks, notes):
    user_dir = stage / "data"
    profile = user_dir / "app.launchsites.easy"
    profile.mkdir(parents=True)
    content = workspace(args.today, events, tasks, notes)
    raw = json.dumps(content, separators=(",", ":"))
    (profile / "shared_preferences.json").write_text(
        json.dumps({"easy.workspace.v1": raw}),
    )
    for name in ("cache", "config", "runtime"):
        (stage / name).mkdir(mode=0o700)
    env = {
        **os.environ,
        "XDG_DATA_HOME": str(user_dir),
        "XDG_CACHE_HOME": str(stage / "cache"),
        "XDG_CONFIG_HOME": str(stage / "config"),
        "XDG_RUNTIME_DIR": str(stage / "runtime"),
        "GDK_BACKEND": "x11",
        "LIBGL_ALWAYS_SOFTWARE": "1",
    }
    report = {
        "profile": label,
        "fixture_bytes": len(raw.encode()),
        "fixture_counts": {key: len(value) for key, value in content.items()},
        "cpu": core,
        "routes": [],
    }
    with (stage / "xvfb.log").open("wb") as display_log, (stage / "app.log").open("wb") as app_log:
        with subprocess.Popen([
            args.xvfb, "-displayfd", "1", "-screen", "0", "1440x1000x24",
            "-nolisten", "tcp", "-ac", "-noreset",
        ], stdout=subprocess.PIPE, stderr=display_log, env=env, text=True) as x11:
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(x11.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=10):
                        raise TimeoutError("The disposable X11 display did not open.")
                    os.environ["DISPLAY"] = env["DISPLAY"] = ":" + x11.stdout.readline().strip()
                launched = time.monotonic()
                with subprocess.Popen([
                    "taskset", "-c", str(core), str(args.binary),
                ], env=env, stdout=app_log, stderr=app_log) as app:
                    try:
                        window, pid = ready_window(args, app)
                        report["window_visible_ms"] = round((time.monotonic() - launched) * 1000, 2)
                        send_input(args.xdotool, "windowfocus", window)
                        send_input(args.xdotool, "windowsize", "--sync", window, 1280, 900)
                        db = profile / "easy" / "workspace.sqlite3"
                        initial_page = check_desktop_route(
                            window, stage, PAGES[0][1], PAGES[0][2], args,
                            timeout=args.readiness_timeout,
                        )
                        report["today_initial"] = initial_page
                        report["today_check_ms_from_launch"] = round((time.monotonic() - launched) * 1000, 2)
                        report["workspace_before"] = wait_for_workspace(db)
                        report["workspace_verified_ms_from_launch"] = round((time.monotonic() - launched) * 1000, 2)
                        for name, y, label in PAGES:
                            started = time.monotonic()
                            send_input(args.xdotool, "mousemove", "--window", window, 76, y, "click", 1)
                            send_input(args.xdotool, "mousemove", "--window", window, 1256, 49)
                            checked = check_desktop_route(window, stage, y, label, args, timeout=20)
                            report["routes"].append({
                                "name": name,
                                "check_ms": round((time.monotonic() - started) * 1000, 2),
                                **checked,
                            })
                        report["workspace_after"] = workspace_state(db)
                        report["process_memory_kib"] = process_rss(pid)
                    except (OSError, RuntimeError, subprocess.SubprocessError, sqlite3.Error) as error:
                        report["error"] = str(error)
                    finally:
                        stop(app)
            finally:
                stop(x11)
    report["workspace_verified"] = (
        "workspace_after" in report
        and report["workspace_before"] == report["workspace_after"]
        and report["workspace_after"]["quick_check"] == "ok"
        and report["workspace_after"]["counts"] == report["fixture_counts"]
    )
    return report


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--today", type=date.fromisoformat, default=date.today())
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--x11-capture", default="import")
    parser.add_argument("--tesseract", default="tesseract")
    parser.add_argument("--readiness-timeout", type=int, default=60)
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    if args.readiness_timeout < 1:
        parser.error("--readiness-timeout must be at least one second.")
    cpus = sorted(os.sched_getaffinity(0))
    evidence = {
        "run_at_utc": datetime.now(timezone.utc).isoformat(),
        "app_revision": args.app_revision,
        "executable_sha256": sha256(args.binary),
        "aot_library_sha256": sha256(args.binary.parent / "lib" / "libapp.so"),
        "host": host_details(cpus),
        "profiles": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="easy-native-scale-") as target:
        for name, events, tasks, notes in PROFILES:
            try:
                report = run_variant(args, cpus[0], Path(target) / name, name, events, tasks, notes)
            except (OSError, RuntimeError, subprocess.SubprocessError, sqlite3.Error) as error:
                report = {"profile": name, "error": str(error)}
            evidence["profiles"].append(report)
            print(report["profile"], report.get("today_check_ms_from_launch"), report.get("error"))
    args.output.write_text(json.dumps(evidence, indent=2) + "\n")
    return int(any(
        not row.get("workspace_verified")
        or not row.get("today_initial", {}).get("selected")
        or any(not route["selected"] for route in row.get("routes", []))
        for row in evidence["profiles"]
    ))


if __name__ == "__main__":
    raise SystemExit(main())
