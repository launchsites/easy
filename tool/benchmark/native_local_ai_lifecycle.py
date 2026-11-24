#!/usr/bin/env python3
"""Exercise Easy's local request lifecycle in a disposable Xfwm/X11 session."""

import argparse
from contextlib import ExitStack
from datetime import date, datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import select
import selectors
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

from PIL import Image

from local_inference import sha256
from native_ui_soak import visible_window, workspace_state
from native_voice_capture import Screen, command, start_child, until


WIDTH, HEIGHT = 1280, 960
CAPTURE = "Task: Run the project build tests before releasing"
TASK = "Draft a reviewed estimate for the copper budget"
MODEL = "easy-lifecycle-fixture"
BUTTON_FILL = (66, 102, 81)


class LoopbackFixture(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.requests = []
        self.disconnected = threading.Event()
        self.request_lock = threading.Lock()


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if self.path != "/v1/chat/completions" or not 0 < length < 100000:
            self.send_error(400)
            return
        envelope = json.loads(self.rfile.read(length))
        fields = json.loads(envelope["messages"][-1]["content"])
        capture = "clauses" in fields
        with self.server.request_lock:
            ordinal = len(self.server.requests)
            self.server.requests.append({
                "at_utc": datetime.now(timezone.utc).isoformat(),
                "kind": "capture" if capture else "estimate",
                "path": self.path,
                "api_credential": self.headers.get("Authorization") is not None,
                "model_matched": envelope["model"] == MODEL,
                "fields": sorted(fields),
                "expected_input": (
                    fields["clauses"][0]["text"] == CAPTURE
                    if capture else fields.get("title") == TASK
                ),
            })
        if capture and ordinal == 0:
            # Hold back response headers while Easy's visible window is minimized.
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                readable, _, _ = select.select([self.connection], [], [], 0.1)
                if readable and not self.connection.recv(1, socket.MSG_PEEK):
                    self.server.disconnected.set()
                    return
        answer = {key: fields[key] for key in ("captureId", "sourceRevision", "contextRevision")}
        if capture:
            answer.update(version=2, suggestions=[{
                "clause": fields["clauses"][0]["clause"], "kind": "category", "category": "work",
            }])
        else:
            answer["minutes"] = 35
        body = json.dumps({"choices": [{"message": {"content": json.dumps(answer)}}]}).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def setup_profile(stage):
    env = dict(os.environ, GDK_BACKEND="x11", GDK_SCALE="1", LIBGL_ALWAYS_SOFTWARE="1",
               GSETTINGS_BACKEND="memory", OMP_THREAD_LIMIT="1")
    for name in ("DATA", "CONFIG", "CACHE", "RUNTIME"):
        folder = stage / name.lower()
        folder.mkdir(mode=0o700)
        env["XDG_RUNTIME_DIR" if name == "RUNTIME" else f"XDG_{name}_HOME"] = str(folder)
    profile = stage / "data" / "app.launchsites.easy"
    profile.mkdir()
    seed = {"events": [], "notes": [], "tasks": [{
        "id": "local-fixture-task", "title": TASK, "category": "work",
        "date": date.today().isoformat(), "done": False,
    }]}
    (profile / "shared_preferences.json").write_text(json.dumps({
        "easy.workspace.v1": json.dumps(seed),
    }))
    return env, profile / "easy"


def launch_app(args, stack, stage, env):
    display = start_child(
        stack, env, stage / "display.log", args.xvfb, "-displayfd", "1", "-screen", "0",
        "1440x1020x24", "-nolisten", "tcp", "-ac", "-noreset", pipe=True,
    )
    with selectors.DefaultSelector() as selector:
        selector.register(display.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=8):
            raise RuntimeError("The isolated X11 display could not start.")
        env["DISPLAY"] = f":{int(display.stdout.readline())}"
    start_child(stack, env, stage / "window-manager.log", args.window_manager,
                "--compositor=off", "--vblank=off")
    until(lambda: "window id" in command(env, "xprop", "-root", "_NET_SUPPORTING_WM_CHECK"),
          "the private X11 window manager")
    app = start_child(stack, env, stage / "app.log", args.binary)

    def locate():
        try:
            window, pid = visible_window(args.xdotool, env=env)
        except subprocess.CalledProcessError:
            return None
        return window if pid == app.pid else None

    screen = Screen(args, stage, env, until(locate, "the disposable Easy window", seconds=50))
    screen.send("windowactivate", "--sync", screen.window)
    screen.send("windowsize", "--sync", screen.window, WIDTH, HEIGHT)
    return screen


def capture_screen(screen):
    command(screen.env, screen.args.x11_capture, "-window", screen.window, screen.path)
    with Image.open(screen.path) as image:
        return image.convert("RGB")


def click(screen, x, y):
    screen.move(x, y)
    screen.send("click", 1)


def scroll_to(screen, label):
    def locate():
        point = screen.find(label)
        if point:
            return point
        screen.move(WIDTH // 2, HEIGHT - 128)
        screen.send("click", "--repeat", 5, "--delay", 70, 5)
        return None

    click(screen, *until(locate, f"the {label!r} settings row"))


def open_settings(screen):
    def opened():
        point = screen.find("Settings")
        if point and point[0] > 300 and point[1] < 70:
            return True
        click(screen, 80, 655)
        return False

    until(opened, "the workspace Settings page")


def save_settings(screen):
    def locate():
        with capture_screen(screen) as image:
            rows = [y for y in range(325, HEIGHT - 10) if image.getpixel((804, y)) == BUTTON_FILL]
        if len(rows) > 16:
            return 804, rows[-1] - 8
        screen.move(WIDTH // 2, HEIGHT - 100)
        screen.send("click", "--repeat", 4, "--delay", 65, 5)
        return None

    click(screen, *until(locate, "the Save settings button"))


def capture_footer(screen):
    def locate():
        with capture_screen(screen) as image:
            if min(image.getpixel((360, HEIGHT // 2))) < 205 or min(image.getpixel((20, HEIGHT // 2))) > 180:
                return None
            footer = max(y for y in range(HEIGHT) if min(image.getpixel((WIDTH // 2, y))) >= 205)
            return footer - 38 if footer < HEIGHT - 10 else None

    return until(locate, "the editable capture footer")


def confirm_dialog(screen, heading, *, cancel=False):
    def locate():
        with capture_screen(screen) as image:
            rows = [y for y in range(HEIGHT) if min(image.getpixel((WIDTH // 2, y))) >= 205]
            if not rows or rows[-1] >= HEIGHT - 5:
                return None
            top, bottom = rows[0], rows[-1]
            crop = image.crop((WIDTH // 2 - 250, top, WIDTH // 2 + 250, min(bottom, top + 80)))
            title_image = screen.path.with_name("dialog-heading.png")
            crop.resize((crop.width * 2, crop.height * 2)).save(title_image)
            y = bottom - 42
            filled = [x for x in range(WIDTH // 2, WIDTH - 10) if image.getpixel((x, y)) == BUTTON_FILL]
        title = command(screen.env, screen.args.tesseract, title_image, "stdout", "--psm", 6)
        return (filled[-1] - 36, y) if heading in title.lower() and len(filled) > 20 else None

    point = until(locate, f"the {heading} confirmation action")
    if cancel:
        screen.send("key", "Escape")
    else:
        click(screen, *point)


def read_workspace(database):
    return workspace_state(database, include_document=True)["document"]


def ai_state(database):
    try:
        return json.loads(read_workspace(database)["aiState"])
    except (FileNotFoundError, KeyError, sqlite3.OperationalError):
        return {}


def type_field(screen, label, value):
    screen.tap(label)
    screen.send("key", "ctrl+a")
    screen.send("type", "--delay", 3, value)


def run(args, stage, evidence):
    env, profile = setup_profile(stage)
    database = profile / "workspace.sqlite3"
    ai_database = profile / "ai-device.sqlite3"
    with LoopbackFixture() as runtime, ExitStack() as stack:
        thread = threading.Thread(target=runtime.serve_forever, daemon=True)
        thread.start()
        stack.callback(thread.join, 3)
        stack.callback(runtime.shutdown)
        screen = launch_app(args, stack, stage, env)
        evidence["step"] = "configure"
        open_settings(screen)
        scroll_to(screen, "monthly limit")
        until(lambda: screen.find("Offline"), "the AI route controls")
        click(screen, 471, 89)
        address = f"http://127.0.0.1:{runtime.server_port}/v1"
        type_field(screen, "Base URL", address)
        type_field(screen, "Model", MODEL)
        save_settings(screen)
        until(lambda: ai_state(ai_database).get("settings", {}).get("localBaseUrl") == address,
              "the local route in the device database")
        evidence["configured"] = True

        click(screen, 27, 28)
        evidence["step"] = "capture review"
        scroll_to(screen, "Capture inbox")
        screen.tap("Capture text")
        screen.send("type", "--delay", 3, CAPTURE)
        click(screen, 730, capture_footer(screen))
        confirm_dialog(screen, "local runtime", cancel=True)
        capture_footer(screen)
        assert not runtime.requests and read_workspace(database)["captures"][0]["text"] == CAPTURE
        evidence["declined_no_request"] = True
        click(screen, 730, capture_footer(screen))
        confirm_dialog(screen, "local runtime")
        until(lambda: runtime.requests, "the approved local request")

        evidence["step"] = "background cancellation"
        screen.send("windowminimize", "--sync", screen.window)
        until(runtime.disconnected.is_set, "the request disconnecting after minimization", seconds=15)
        current = read_workspace(database)
        assert len(runtime.requests) == 1 and len(current["tasks"]) == 1
        assert not current["captures"][0]["applied"]
        evidence["active_capture_cancelled_on_background"] = True
        screen.send("windowactivate", "--sync", screen.window)
        click(screen, 730, capture_footer(screen))
        confirm_dialog(screen, "local runtime")
        until(lambda: screen.find("suggestion"), "the validated local category draft")
        assert len(read_workspace(database)["tasks"]) == 1
        evidence["review_only"] = True

        evidence["step"] = "enable automatic estimates"
        title = until(lambda: screen.find("Capture review"), "the capture review title")
        click(screen, WIDTH // 2 + 240, title[1])
        scroll_to(screen, "monthly limit")
        scroll_to(screen, "Suggest durations")
        scroll_to(screen, "Use spare capacity")
        scroll_to(screen, "Use more foreground time")
        save_settings(screen)
        confirm_dialog(screen, "automatic estimates")
        until(lambda: ai_state(ai_database).get("settings", {}).get("adaptiveEstimatePacing") is True,
              "automatic opt-in persisted")
        click(screen, 27, 28)
        until(lambda: screen.find("Settings"), "the workspace Settings page")
        click(screen, 346, 42)
        until(lambda: screen.find("All spaces"), "the foreground workspace")

        evidence["step"] = "idle in background"
        screen.send("windowminimize", "--sync", screen.window)
        began = time.monotonic()
        while time.monotonic() - began < 130:
            assert len(runtime.requests) == 2
            time.sleep(1)
        evidence["background_idle_no_request"] = True
        evidence["background_idle_seconds"] = round(time.monotonic() - began, 2)

        evidence["step"] = "foreground estimate queued"
        screen.send("windowactivate", "--sync", screen.window)
        until(lambda: len(runtime.requests) == 3, "the foreground estimate", seconds=150)
        until(lambda: ai_state(ai_database).get("enrichment", {}).get("pending"), "the persisted review estimate")
        assert read_workspace(database)["tasks"][0].get("estimatedMinutes") is None
        evidence["estimate_review_only"] = True
        open_settings(screen)
        scroll_to(screen, "Duration suggestions")
        until(lambda: screen.find("35 min"), "the local estimate in Settings")
        screen.tap("Use estimate")
        until(lambda: read_workspace(database)["tasks"][0].get("estimatedMinutes") == 35,
              "the confirmed timing in workspace SQLite")
        final = workspace_state(database)
        assert final["quick_check"] == "ok" and len(runtime.requests) == 3
        assert all(request["model_matched"] and request["expected_input"] and not request["api_credential"]
                   for request in runtime.requests)
        evidence.update(status="passed", workspace=final, requests=runtime.requests, final_minutes=35)
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
    with tempfile.TemporaryDirectory(prefix="easy-local-lifecycle-") as directory:
        stage = Path(directory)
        try:
            run(args, stage, evidence)
        finally:
            if args.failure_image and evidence["status"] != "passed" and (stage / "screen.png").is_file():
                args.failure_image.write_bytes((stage / "screen.png").read_bytes())
            args.output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
