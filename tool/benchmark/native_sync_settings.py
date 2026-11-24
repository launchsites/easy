#!/usr/bin/env python3
"""Exercise Linux manual sync setup and restart in a disposable profile."""

import argparse
from contextlib import ExitStack, closing, contextmanager
import csv
import io
import json
import os
from pathlib import Path
import re
import selectors
import signal
import sqlite3
import subprocess
import tempfile
import time

from local_inference import sha256
from local_speech import words
from native_ui_soak import visible_window, workspace_state
from native_voice_capture import Screen, command, start_child, until


VIEWPORT = (1280, 720)
MARKER = "easy.manualSync.installation.v1"
FIXTURE_TITLE = "Synthetic saved record"
PASSPHRASE = "Synthetic native setup test passphrase"
WRONG_PASSPHRASE = "Synthetic unlock mismatch"


def profile_environment(stage):
    env = dict(os.environ, GDK_BACKEND="x11", LIBGL_ALWAYS_SOFTWARE="1",
               GSETTINGS_BACKEND="memory", OMP_THREAD_LIMIT="1", NO_AT_BRIDGE="1")
    for name in ("WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
        env.pop(name, None)
    for name in ("DATA", "CONFIG", "CACHE", "RUNTIME"):
        directory = stage / name.lower()
        directory.mkdir(mode=0o700)
        key = "XDG_RUNTIME_DIR" if name == "RUNTIME" else f"XDG_{name}_HOME"
        env[key] = str(directory)
    profile = stage / "data" / "app.launchsites.easy"
    profile.mkdir()
    initial = {"tasks": [{"id": "fixture", "title": FIXTURE_TITLE,
                          "category": "work", "done": False}], "events": [], "notes": []}
    (profile / "shared_preferences.json").write_text(json.dumps({
        "easy.workspace.v1": json.dumps(initial),
    }))
    return env, profile


@contextmanager
def isolated_app(args, stage, env, name):
    # A separate D-Bus session with no Secret Service demonstrates the Linux
    # passphrase path without opening any credentials from the host session.
    script = '''set -eu
owner=$(gdbus call --session --dest org.freedesktop.DBus \
 --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
 org.freedesktop.secrets)
[ "$owner" = '(false,)' ]
exec "$1"
'''
    with ExitStack() as stack:
        app = start_child(
            stack, env, stage / f"{name}.log", args.dbus_run_session,
            "--", "sh", "-c", script, "easy-sync-probe", args.binary,
        )

        def find_window():
            if app.poll() is not None:
                raise RuntimeError("Easy quit before rendering a window.")
            try:
                return visible_window(args.xdotool, env=env)
            except subprocess.CalledProcessError as error:
                if error.returncode == 1:
                    return None
                raise

        window, pid = until(find_window, "the isolated Easy window", seconds=args.timeout)
        if Path(f"/proc/{pid}/exe").resolve() != args.binary:
            raise RuntimeError("Unexpected process owns the isolated window.")
        screen = Screen(args, stage, env, window)
        screen.send("windowfocus", window)
        geometry = command(env, args.xdotool, "getwindowgeometry", "--shell", window)
        if any(f"{key}={value}" not in geometry.splitlines()
               for key, value in zip(("WIDTH", "HEIGHT"), VIEWPORT)):
            raise RuntimeError("The native app did not open at the fixture viewport.")
        try:
            yield screen
        finally:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            app.wait(timeout=12)


def click(screen, x, y):
    screen.move(x, y)
    screen.send("click", 1)


def accent_exists(args, screen, x, y):
    raw = subprocess.check_output([
        args.x11_capture, "-window", screen.window, "-crop", f"1x1+{x}+{y}",
        "-depth", "8", "rgb:-",
    ], env=screen.env, timeout=8)
    if len(raw) != 3:
        return False
    red, leaf, blue = raw
    return leaf > red + 16 and leaf > blue + 12 and leaf < 161


def cropped_label(args, screen, text, region):
    left, top, width, height = region
    crop = screen.path.with_name("sync-crop.png")
    command(screen.env, args.x11_capture, "-window", screen.window,
            "-crop", f"{width}x{height}+{left}+{top}", "+repage", "-resize", "200%", crop)
    output = command(screen.env, args.tesseract, crop, "stdout", "--psm", 6, "tsv")
    lines = {}
    for row in csv.DictReader(io.StringIO(output), delimiter="\t"):
        if row["level"] == "5" and row["text"].strip():
            key = (row["block_num"], row["par_num"], row["line_num"])
            lines.setdefault(key, []).append(row)
    target = words(text)
    for line in lines.values():
        tokens = [(token, row) for row in line for token in words(row["text"])]
        for index in range(len(tokens) - len(target) + 1):
            match = tokens[index:index + len(target)]
            if [word for word, _ in match] != target:
                continue
            first, last = match[0][1], match[-1][1]
            return (
                left + (int(first["left"]) + int(last["left"]) + int(last["width"])) // 4,
                top + (int(first["top"]) + int(first["height"]) // 2) // 2,
            )
    return None


def check(args, screen, label, *, region=None):
    if region is None:
        return until(lambda: screen.find(label), repr(label), seconds=args.timeout)
    try:
        return until(lambda: cropped_label(args, screen, label, region), repr(label),
                     seconds=args.timeout)
    except RuntimeError:
        command(screen.env, args.x11_capture, "-window", screen.window, screen.path)
        raise


def cancel_passphrase(args, screen):
    # Use the visible filled action as an anchor when OCR drops the text
    # actions. The adjacent leading action is Cancel in these LTR dialogs.
    left, top, width, height = 535, 380, 420, 180
    raw = subprocess.check_output([
        args.x11_capture, "-window", screen.window,
        "-crop", f"{width}x{height}+{left}+{top}", "-depth", "8", "rgb:-",
    ], env=screen.env, timeout=8)
    runs = []
    for y in range(height):
        start = None
        for x in range(width + 1):
            green = False
            if x < width:
                offset = 3 * (y * width + x)
                red, leaf, blue = raw[offset:offset + 3]
                green = leaf > red + 16 and leaf > blue + 12 and leaf < 161
            if green:
                if start is None:
                    start = x
            elif start is not None:
                if 53 <= x - start <= 135:
                    runs.append((x - start, start, y))
                start = None
    if not runs:
        raise RuntimeError("Could not find the passphrase dialog actions.")
    longest = max(length for length, _, _ in runs)
    action = [run for run in runs if run[0] >= longest - 5]
    _, x, y = action[len(action) // 2]
    click(screen, left + x - 42, top + y)


def find_manual_sync(args, screen):
    click(screen, *check(args, screen, "Settings", region=(12, 610, 188, 82)))
    check(args, screen, "Workspace")
    screen.move(670, 560)
    location = None
    for _ in range(8):
        candidate = screen.find("exchange encrypted files")
        if candidate is not None:
            def settled_location():
                nonlocal candidate
                current = screen.find("exchange encrypted files")
                if current == candidate and current is not None:
                    return current
                candidate = current
                return None

            location = until(settled_location, "the stationary manual sync row")
            break
        screen.send("click", "--repeat", 5, 5)
        time.sleep(0.45)
    if location is None:
        raise RuntimeError("Manual sync was not visible in Workspace Settings.")
    click(screen, location[0], location[1] - 15)
    check(args, screen, "Manual", region=(66, 6, 205, 46))


def enter_passphrase(args, screen, text, *, setup=False, replace=False):
    # This X11 display belongs only to the fixture, including its clipboard.
    subprocess.run([args.xclip, "-selection", "clipboard", "-in"],
                   input=text, text=True, env=screen.env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
    if setup:
        # The action probe uses the fixed desktop viewport and original theme.
        click(screen, 470, 345)
    elif replace:
        # An unlock error can disable and re-enable the input in this revision.
        click(screen, 470, 354)
    if replace:
        screen.send("key", "ctrl+a")
    screen.send("key", "ctrl+v")
    time.sleep(0.25)
    if setup:
        click(screen, 470, 404)
        screen.send("key", "ctrl+v")
        time.sleep(0.25)
        click(screen, 846, 465)
    else:
        screen.send("key", "Return")


def run(args, stage):
    env, profile = profile_environment(stage)
    preferences = profile / "shared_preferences.json"
    storage = profile / "easy"
    vault = storage / "sync" / "credentials.easyvault"
    prompt = (340, 180, 600, 420)
    paired_heading = (315, 213, 270, 38)

    def read_marker():
        return json.loads(preferences.read_text()).get(MARKER)

    def snapshot():
        try:
            return workspace_state(storage / "workspace.sqlite3", include_document=True)
        except sqlite3.OperationalError:
            return None

    with ExitStack() as stack:
        display = start_child(
            stack, env, stage / "xvfb.log", args.xvfb, "-displayfd", "1", "-screen", "0",
            "1440x1000x24", "-nolisten", "tcp", "-noreset", "-ac", pipe=True,
        )
        with selectors.DefaultSelector() as selector:
            selector.register(display.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=10):
                raise RuntimeError("The private X11 display did not start.")
            env["DISPLAY"] = f":{int(display.stdout.readline())}"
        with isolated_app(args, stage, env, "setup") as screen:
            first = until(snapshot, "the synthetic workspace", seconds=args.timeout)
            find_manual_sync(args, screen)
            until(lambda: accent_exists(args, screen, 400, 168), "the enabled setup action")
            click(screen, 410, 181)
            check(args, screen, "Protect sync", region=prompt)
            cancel_passphrase(args, screen)
            until(lambda: accent_exists(args, screen, 400, 168), "the setup action after cancellation")
            if read_marker() is not None or vault.exists() or list((storage / "sync").glob("*.sqlite3")):
                raise RuntimeError("Cancelling setup unexpectedly wrote sync state.")
            click(screen, 410, 181)
            check(args, screen, "Protect sync", region=prompt)
            enter_passphrase(args, screen, PASSPHRASE, setup=True)
            check(args, screen, "Paired devices", region=paired_heading)

        marker = json.loads(read_marker())
        if len(marker) != 3 or marker[0] != 1 or marker[2] is not True:
            raise RuntimeError("The completed setup marker is invalid.")
        journal = storage / "sync" / f"{marker[1]}.sqlite3"
        original_vault = sha256(vault)
        with closing(sqlite3.connect(journal.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                raise RuntimeError("The new sync journal failed its integrity check.")
        if PASSPHRASE.encode() in vault.read_bytes() or PASSPHRASE in preferences.read_text():
            raise RuntimeError("The fixture passphrase appeared in persisted state.")

        with isolated_app(args, stage, env, "reopen") as screen:
            find_manual_sync(args, screen)
            check(args, screen, "Unlock sync", region=prompt)
            cancel_passphrase(args, screen)
            check(args, screen, "vault is locked")
            click(screen, *check(args, screen, "Unlock"))
            check(args, screen, "Unlock sync", region=prompt)
            enter_passphrase(args, screen, WRONG_PASSPHRASE)
            check(args, screen, "passphrase could not unlock", region=prompt)
            enter_passphrase(args, screen, PASSPHRASE, replace=True)
            check(args, screen, "Paired devices", region=paired_heading)

    if json.loads(read_marker()) != marker or sha256(vault) != original_vault or snapshot() != first:
        raise RuntimeError("An unlock or restart changed the committed workspace or vault.")
    return {"setup_cancel_preserves_state": True, "wrong_passphrase_rejected": True,
            "configured_unlock_cancelled": True, "restart_opens_same_vault": True,
            "native_journal_integrity": "ok", "workspace_unchanged": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--xclip", default="xclip")
    parser.add_argument("--x11-capture", default="import")
    parser.add_argument("--tesseract", default="tesseract")
    parser.add_argument("--dbus-run-session", default="dbus-run-session")
    parser.add_argument("--timeout", type=float, default=35)
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    if re.fullmatch(r"[0-9a-f]{40}", args.revision) is None or args.timeout <= 0:
        parser.error("Provide a full source revision and a positive timeout.")
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="easy-native-sync-") as scratch:
        checks = run(args, Path(scratch))
    app = args.binary.parent / "lib" / "libapp.so"
    report = {"revision": args.revision, "executable_sha256": sha256(args.binary),
              "aot_sha256": sha256(app), "viewport": VIEWPORT,
              "secret_service_on_launch": False,
              "elapsed_seconds": round(time.monotonic() - started, 2), "checks": checks}
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
