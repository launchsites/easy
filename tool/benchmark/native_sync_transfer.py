#!/usr/bin/env python3
"""Apply one reviewed encrypted change file between two Linux AOT profiles."""

from contextlib import ExitStack, closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

from local_inference import sha256
from native_sync_installation_race import display_environment
from native_sync_settings import (
    FIXTURE_TITLE, PASSPHRASE, VIEWPORT, check, click, enter_passphrase,
    find_manual_sync, isolated_app, probe_arguments, profile_environment,
)
from native_ui_soak import workspace_state
from native_voice_capture import command, until


DESTINATION_TITLE = "Private destination record"
LOCAL_NOTE = "Unselected source note"
PANEL = (310, 54, 660, 580)
PROMPT = (335, 174, 610, 438)
FOOTER = (730, 636, 549, 84)


def profiles(args, stage):
    result = []
    for name in ("source", "destination"):
        folder = stage / name
        folder.mkdir()
        env, profile = profile_environment(folder)
        preferences = profile / "shared_preferences.json"
        old = json.loads(preferences.read_text())
        data = json.loads(old["easy.workspace.v1"])
        if name == "source":
            data["notes"] = [{"id": "stay-local", "title": LOCAL_NOTE, "body": "Synthetic note",
                              "updated": "2026-11-22T10:00:00.000Z"}]
        else:
            data["tasks"] = [{"id": "destination", "title": DESTINATION_TITLE,
                              "category": "personal", "done": False}]
        old["easy.workspace.v1"] = json.dumps(data)
        preferences.write_text(json.dumps(old))
        result.append((folder, env, profile))
    generated = subprocess.run([
        args.flutter, "test", "--no-pub", "--reporter", "expanded",
        "tool/benchmark/native_sync_transfer_fixture_test.dart",
    ], capture_output=True, text=True, timeout=180,
       env={**os.environ, "EASY_SYNC_TRANSFER_FIXTURE": str(stage)})
    if generated.returncode:
        raise RuntimeError(f"Paired profile fixture failed.\n{generated.stdout}\n{generated.stderr}")
    return result


def records(profile):
    return workspace_state(profile / "easy" / "workspace.sqlite3", include_document=True)


def journal_head(profile):
    folder = profile / "easy" / "sync"
    _, workspace_id, _ = json.loads((folder / "installation.json").read_text())
    database = folder / f"{workspace_id}.sqlite3"
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        return db.execute("SELECT revision, bytes, auth FROM sync_head WHERE id = 1").fetchone()


def wait_for_records(profile, timeout):
    def ready():
        try:
            return records(profile)
        except sqlite3.OperationalError:
            return None
    return until(ready, "the seeded workspace", seconds=timeout)


def tap_label(args, screen, label):
    click(screen, *check(args, screen, label, region=PANEL))


def filled_action(args, screen, region):
    left, top, width, height = region

    def location():
        pixels = subprocess.check_output([
            args.x11_capture, "-window", screen.window,
            "-crop", f"{width}x{height}+{left}+{top}", "-depth", "8", "rgb:-",
        ], env=screen.env, timeout=8)
        spans = []
        for y in range(height):
            start = None
            for x in range(width + 1):
                if x < width:
                    offset = 3 * (y * width + x)
                    red, green, blue = pixels[offset:offset + 3]
                    if green > red + 16 and green > blue + 12 and green < 161:
                        if start is None:
                            start = x
                        continue
                if start is not None:
                    if 53 <= x - start <= 235:
                        spans.append((x - start, start, y))
                    start = None
        buttons = [
            (length, x, y) for length, x, y in spans
            if len({row for other_length, other_x, row in spans
                    if abs(y - row) <= 9 and abs(x - other_x) <= 7
                    and abs(length - other_length) <= 16}) >= 7
        ]
        if not buttons:
            return None
        longest = max(length for length, _, _ in buttons)
        solid = [part for part in buttons if part[0] >= longest - 3]
        length, x, y = solid[len(solid) // 2]
        return left + x + length // 2, top + y

    click(screen, *until(location, "the filled action", seconds=args.timeout))


def picker_path(args, screen, label, destination):
    if not destination.is_absolute() or not str(destination).startswith(tempfile.gettempdir() + os.sep):
        raise RuntimeError("A disposable file path is required.")

    def open_picker():
        try:
            matches = command(screen.env, args.xdotool, "search", "--onlyvisible",
                              "--name", f"^{label}$").splitlines()
        except subprocess.CalledProcessError as error:
            if error.returncode == 1:
                return None
            raise
        if len(matches) != 1:
            raise RuntimeError("Expected one file chooser in the isolated display.")
        return matches[0]

    picker = until(open_picker, label, seconds=args.timeout)
    screen.send("windowfocus", picker)
    command(screen.env, args.x11_capture, "-window", picker, screen.path.with_name("chooser.png"))
    screen.send("key", "ctrl+l", "ctrl+a")
    screen.send("type", "--delay", 1, "--clearmodifiers", str(destination))
    time.sleep(0.25)
    command(screen.env, args.x11_capture, "-window", picker,
            screen.path.with_name("chooser-selection.png"))
    screen.send("key", "Return")


def complete_bundle(path):
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    if not data:
        return None
    if (not data.startswith(b"EASYSYN\x00") or
            FIXTURE_TITLE.encode() in data or LOCAL_NOTE.encode() in data):
        raise RuntimeError("The exported file failed the encryption checks.")
    return data


def open_peer_settings(args, screen):
    find_manual_sync(args, screen)
    check(args, screen, "Unlock sync", region=PROMPT)
    enter_passphrase(args, screen, PASSPHRASE)
    check(args, screen, "Paired devices", region=(315, 213, 270, 38))
    click(screen, 430, 271)
    check(args, screen, "Device fingerprint", region=(331, 70, 240, 50))


def run(args, stage):
    source, destination = profiles(args, stage)
    with ExitStack() as displays:
        source_env = display_environment(args, source[0], displays, source[1], "source")
        destination_env = display_environment(args, destination[0], displays, destination[1], "destination")
        with ExitStack() as apps:
            left = apps.enter_context(isolated_app(args, source[0], source_env, "export"))
            right = apps.enter_context(isolated_app(args, destination[0], destination_env, "import"))
            source_initial = wait_for_records(source[2], args.timeout)
            destination_initial = wait_for_records(destination[2], args.timeout)
            destination_journal = journal_head(destination[2])
            for screen in (left, right):
                open_peer_settings(args, screen)

            tap_label(args, left, "Choose records")
            check(args, left, "Find saved records", region=PANEL)
            tap_label(args, left, FIXTURE_TITLE)
            filled_action(args, left, FOOTER)
            check(args, left, "staged", region=PANEL)
            filled_action(args, left, (315, 177, 302, 124))
            check(args, left, "Progress code from", region=PROMPT)
            filled_action(args, left, (560, 422, 635, 143))

            bundle = stage / "selected-record.easysync"
            picker_path(args, left, "Save File", bundle)
            ciphertext = until(lambda: complete_bundle(bundle), "the encrypted change file",
                               seconds=args.timeout)

            tampered = stage / "damaged-record.easysync"
            tampered.write_bytes(ciphertext[:-1] + bytes([ciphertext[-1] ^ 1]))
            tap_label(args, right, "Open change bundle")
            picker_path(args, right, "Open File", tampered)
            check(args, right, "The file or code could not be verified for this device", region=PANEL)
            if (records(destination[2]) != destination_initial or
                    journal_head(destination[2]) != destination_journal):
                raise RuntimeError("A damaged bundle changed the saved workspace or sync journal.")

            tap_label(args, right, "Open change bundle")
            picker_path(args, right, "Open File", bundle)
            check(args, right, FIXTURE_TITLE, region=PANEL)
            if (records(destination[2]) != destination_initial or
                    journal_head(destination[2]) != destination_journal):
                raise RuntimeError("Opening the bundle changed saved workspace or journal records.")
            filled_action(args, right, FOOTER)
            check(args, right, "Saved to the sync journal", region=PANEL)
            if (records(destination[2]) != destination_initial or
                    journal_head(destination[2]) == destination_journal):
                raise RuntimeError("Approving the bundle failed to save only the journal.")
            filled_action(args, right, FOOTER)
            check(args, right, "Choose changes for your workspace", region=PANEL)
            tap_label(args, right, FIXTURE_TITLE)
            filled_action(args, right, FOOTER)
            check(args, right, "recovery point first", region=PROMPT)
            filled_action(args, right, (590, 344, 442, 208))

            def applied():
                saved = records(destination[2])
                return saved if saved["revision"] == destination_initial["revision"] + 1 else None

            accepted = until(applied, "the selected workspace save", seconds=args.timeout)
            saved_tasks = {task["title"] for task in accepted["document"]["tasks"]}
            if accepted["quick_check"] != "ok" or saved_tasks != {FIXTURE_TITLE, DESTINATION_TITLE} or accepted["document"]["notes"]:
                raise RuntimeError("The live workspace diverged from the selected records.")
            if records(source[2]) != source_initial:
                raise RuntimeError("Export changed the source workspace.")

        database = destination[2] / "easy" / "workspace.sqlite3"
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            prior = db.execute("SELECT workspace FROM revisions WHERE revision = ?",
                               (destination_initial["revision"],)).fetchone()
            if prior != (destination_initial["digest"],):
                raise RuntimeError("The workspace lost the pre-apply revision.")
        with isolated_app(args, destination[0], destination_env, "reopen") as reopened:
            check(args, reopened, "Focus modes", region=(16, 290, 190, 51))
            click(reopened, 80, 194)
            check(args, reopened, FIXTURE_TITLE)
            if records(destination[2]) != accepted:
                raise RuntimeError("Restart changed the accepted workspace.")

    return {"prepaired_synthetic_profiles": 2, "native_file_chooser_export_import": True,
            "encrypted_bundle_bytes": len(ciphertext), "workspace_revision_before_apply": destination_initial["revision"],
            "workspace_revision_after_apply": accepted["revision"], "source_digest_unchanged": True,
            "damaged_ciphertext_rejected": True, "rejection_preserved_workspace_and_sealed_head": True,
            "pre_apply_digest_retained": True, "destination_restart_digest_matches": True,
            "only_selected_record_applied": True, "destination_sqlite_integrity": "ok"}


def main():
    args = probe_arguments(__doc__, seed_profiles=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="easy-native-sync-transfer-") as scratch:
        checks = run(args, Path(scratch))
    report = {"source_revision": args.revision, "executable_sha256": sha256(args.binary),
              "aot_sha256": sha256(args.binary.parent / "lib" / "libapp.so"), "viewport": VIEWPORT,
              "elapsed_seconds": round(time.monotonic() - started, 2), "checks": checks}
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
