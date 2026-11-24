#!/usr/bin/env python3
"""Start two Linux Easy processes on one disposable native sync profile."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
import json
import os
from pathlib import Path
import selectors
import signal
import sqlite3
import subprocess
import tempfile
import time

from local_inference import sha256
from native_sync_settings import (
    PASSPHRASE, VIEWPORT, accent_exists, check, click, enter_passphrase,
    find_manual_sync, isolated_app, probe_arguments, profile_environment,
)
from native_ui_soak import workspace_state
from native_voice_capture import command, start_child, until


def display_environment(args, stage, stack, env, label):
    child_env = env.copy()
    display = start_child(
        stack, child_env, stage / f"{label}-xvfb.log", args.xvfb, "-displayfd", "1",
        "-screen", "0", "1440x1000x24", "-nolisten", "tcp", "-noreset", "-ac", pipe=True,
    )
    with selectors.DefaultSelector() as selector:
        selector.register(display.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError("The private race display did not start.")
        child_env["DISPLAY"] = f":{int(display.stdout.readline())}"
    return child_env


def visible_identity(args, screen):
    # Both views show the 64-character fingerprint in this screen region.
    return subprocess.check_output([
        args.x11_capture, "-window", screen.window, "-crop", "593x21+334+112",
        "-depth", "8", "rgb:-",
    ], env=screen.env, timeout=8)


def interrupt_at_pending_marker(args, screen, marker):
    pid = int(command(screen.env, args.xdotool, "getwindowpid", screen.window))
    if Path(f"/proc/{pid}/exe").resolve() != args.binary:
        raise RuntimeError("Unexpected process owns the setup window.")
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        try:
            data = json.loads(marker.read_text())
        except FileNotFoundError:
            pass
        else:
            version, workspace, ready = data
            if version == 1 and ready is False:
                os.kill(pid, signal.SIGKILL)
                return workspace
            if ready is True:
                raise RuntimeError("The app finished setup before interruption.")
        time.sleep(0.01)
    raise RuntimeError("Timed out waiting for a durable pending marker.")


def run(args, stage):
    env, profile = profile_environment(stage)
    root = profile / "easy"
    sync = root / "sync"
    marker = sync / "installation.json"
    vault_file = sync / "credentials.easyvault"
    prompt = (340, 180, 600, 420)
    paired_heading = (315, 213, 270, 38)

    def saved_workspace():
        try:
            return workspace_state(root / "workspace.sqlite3")
        except sqlite3.OperationalError:
            return None

    with ExitStack() as displays:
        environments = [
            display_environment(args, stage, displays, env, label)
            for label in ("first", "second")
        ]
        with ExitStack() as processes:
            screens = []
            for index, item_env in enumerate(environments):
                evidence = stage / f"profile-{index}"
                evidence.mkdir()
                screens.append(processes.enter_context(
                    isolated_app(args, evidence, item_env, "race"),
                ))
                before = until(saved_workspace, "the seeded workspace", seconds=args.timeout)
            for screen in screens:
                find_manual_sync(args, screen)
                until(lambda: accent_exists(args, screen, 400, 168), "an available setup action")
                click(screen, 410, 181)
                check(args, screen, "Protect sync", region=prompt)
            if marker.exists() or vault_file.exists():
                raise RuntimeError("A setup prompt published sync state before approval.")

            pending_workspace = None
            if args.interrupt_first:
                with ThreadPoolExecutor(max_workers=1) as pool:
                    watcher = pool.submit(interrupt_at_pending_marker, args, screens[0], marker)
                    enter_passphrase(args, screens[0], PASSPHRASE, setup=True)
                    pending_workspace = watcher.result(timeout=args.timeout)
                enter_passphrase(args, screens[1], PASSPHRASE, setup=True)
                survivors = screens[1:]
            else:
                with ThreadPoolExecutor(max_workers=2) as pool:
                    list(pool.map(
                        lambda screen: enter_passphrase(args, screen, PASSPHRASE, setup=True),
                        screens,
                    ))
                survivors = screens
            for screen in survivors:
                check(args, screen, "Paired devices", region=paired_heading)
                screen.move(1050, 650)

            identities = [visible_identity(args, screen) for screen in survivors]
            if len(set(identities[0])) < 8 or any(item != identities[0] for item in identities):
                raise RuntimeError("The native routes did not display the shared identity.")
            config = json.loads(marker.read_text())
            if len(config) != 3 or config[0] != 1 or config[2] is not True:
                raise RuntimeError("The shared profile did not commit one ready marker.")
            if pending_workspace is not None and config[1] != pending_workspace:
                raise RuntimeError("Restart replaced the interrupted workspace ID.")
            journals = list(sync.glob("*.sqlite3"))
            if [file.name for file in journals] != [f"{config[1]}.sqlite3"]:
                raise RuntimeError("The concurrent setup left additional journals.")
            with closing(sqlite3.connect(journals[0].resolve().as_uri() + "?mode=ro", uri=True)) as db:
                if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                    raise RuntimeError("The shared journal failed its integrity check.")
            vault_before = sha256(vault_file)

        reopened = stage / "reopened"
        reopened.mkdir()
        with isolated_app(args, reopened, environments[0], "restart") as screen:
            find_manual_sync(args, screen)
            check(args, screen, "Unlock sync", region=prompt)
            enter_passphrase(args, screen, PASSPHRASE)
            check(args, screen, "Paired devices", region=paired_heading)
            screen.move(1050, 650)
            if visible_identity(args, screen) != identities[0]:
                raise RuntimeError("Restart did not reopen the shared installation identity.")
    if json.loads(marker.read_text()) != config or sha256(vault_file) != vault_before or saved_workspace() != before:
        raise RuntimeError("Restart changed the shared installation or workspace.")
    checks = {"setup_processes": 2, "journal_count": 1, "journal_integrity": "ok",
              "restart_identity_matches": True, "vault_and_workspace_unchanged": True}
    if pending_workspace is not None:
        checks["interrupted_at_pending_marker"] = True
        checks["resumed_same_pending_workspace"] = True
    else:
        checks["matching_identity_displays"] = True
    return checks


def main():
    args = probe_arguments(__doc__, accept_interruption=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="easy-native-sync-race-") as scratch:
        checks = run(args, Path(scratch))
    report = {
        "source_revision": args.revision, "executable_sha256": sha256(args.binary),
        "aot_sha256": sha256(args.binary.parent / "lib" / "libapp.so"),
        "viewport": VIEWPORT, "private_x11_and_dbus_sessions": True,
        "elapsed_seconds": round(time.monotonic() - started, 2), "checks": checks,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
