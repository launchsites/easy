#!/usr/bin/env python3
"""Pair two fresh Linux AOT apps through their actual comparison dialogs."""

from contextlib import ExitStack, closing
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time

from local_inference import sha256
from native_sync_installation_race import display_environment, visible_identity
from native_sync_settings import (
    PASSPHRASE, VIEWPORT, accent_exists, check, click, enter_passphrase,
    find_manual_sync, isolated_app, probe_arguments, profile_environment,
)
from native_sync_transfer import PANEL, PROMPT, filled_action, records, wait_for_records
from native_voice_capture import command, until


PAIRED_HEADING = (315, 213, 270, 38)
PAIRING_TOKEN = re.compile(r"easy-pair1:[a-zA-Z0-9_.:=\-]{64,}")
COMPARISON_CODE = re.compile(r"[A-Z0-9]{4}-[A-Z0-9]{4}")


def clipboard(args, screen):
    try:
        return command(screen.env, args.xclip, "-selection", "clipboard", "-o").strip()
    except subprocess.CalledProcessError:
        return ""


def copy_token(args, screen, heading):
    check(args, screen, heading, region=PANEL)
    earlier = clipboard(args, screen)
    # Each card places its leading copy action below the explanation.
    click(screen, 404, 164)

    def copied():
        token = clipboard(args, screen)
        return token if token != earlier and PAIRING_TOKEN.fullmatch(token) else None

    return until(copied, "a new native clipboard token", seconds=args.timeout)


def paste_token(args, screen, label, token):
    check(args, screen, label, region=PROMPT)
    subprocess.run([args.xclip, "-selection", "clipboard", "-in"],
                   input=token, text=True, env=screen.env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
    until(lambda: clipboard(args, screen) == token, "the exact fixture token")
    click(screen, *check(args, screen, "Paste from clipboard", region=PROMPT))
    filled_action(args, screen, (628, 405, 275, 155))


def displayed_comparison(args, screen):
    _, heading_y = check(args, screen, "Compare both screens", region=PANEL)
    for y in range(heading_y + 70, heading_y + 144, 12):
        click(screen, 387, y)
        screen.send("key", "ctrl+a", "ctrl+c")
        value = clipboard(args, screen)
        if COMPARISON_CODE.fullmatch(value):
            return value
    raise RuntimeError("The displayed comparison code could not be selected.")


def confirm_comparison(args, screen, code):
    filled_action(args, screen, (315, 152, 620, 399))
    check(args, screen, "Confirm matching codes", region=PROMPT)
    click(screen, *check(args, screen, "Code shown on the other device", region=PROMPT))
    screen.send("type", "--delay", 45, "--clearmodifiers", code)
    screen.send("key", "Return")
    return copy_token(args, screen, "Exchange approvals")


def enter_approval(args, screen, approval):
    filled_action(args, screen, (320, 116, 620, 171))
    paste_token(args, screen, "Approval token", approval)


def visible_peer(args, screen):
    check(args, screen, "Paired devices", region=PAIRED_HEADING)
    click(screen, 430, 271)
    check(args, screen, "Device fingerprint", region=(331, 70, 240, 50))
    return visible_identity(args, screen)


def pair(args, first, second):
    click(first, 410, 181)
    check(args, first, "Protect sync", region=PROMPT)
    enter_passphrase(args, first, PASSPHRASE, setup=True)
    check(args, first, "Paired devices", region=PAIRED_HEADING)
    click(first, 396, 181)
    check(args, first, "Pair with the person", region=PANEL)
    filled_action(args, first, (315, 103, 365, 61))
    offer = copy_token(args, first, "Share this invitation")

    click(second, 567, 181)
    check(args, second, "Pair with the person", region=PANEL)
    click(second, 396, 122)
    paste_token(args, second, "Invitation token", offer)
    check(args, second, "Check the inviting device", region=PANEL)
    filled_action(args, second, (320, 129, 605, 200))
    check(args, second, "Protect sync", region=PROMPT)
    enter_passphrase(args, second, PASSPHRASE, setup=True)
    response = copy_token(args, second, "Send the response")

    filled_action(args, first, (321, 121, 540, 130))
    paste_token(args, first, "Response token", response)
    first_code = displayed_comparison(args, first)
    second_code = displayed_comparison(args, second)
    if first_code != second_code:
        raise RuntimeError("The two native comparison screens showed different codes.")
    first_approval = confirm_comparison(args, first, second_code)
    second_approval = confirm_comparison(args, second, first_code)

    enter_approval(args, first, first_approval)
    check(args, first, "pairing code could not be authenticated", region=PANEL)
    enter_approval(args, first, second_approval)
    enter_approval(args, second, first_approval)
    return [visible_peer(args, screen) for screen in (first, second)]


def setup_proof(profile):
    sync = profile / "easy" / "sync"
    marker = json.loads((sync / "installation.json").read_text())
    version, workspace_id, ready = marker
    if version != 1 or ready is not True:
        raise RuntimeError("The native pairing installation marker is not ready.")
    journal = sync / f"{workspace_id}.sqlite3"
    if list(sync.glob("*.sqlite3")) != [journal]:
        raise RuntimeError("Pairing did not retain exactly one journal on this device.")
    with closing(sqlite3.connect(journal.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("The paired SQLite journal failed its integrity check.")
    return workspace_id, sha256(sync / "credentials.easyvault")


def run(args, stage):
    peers = []
    with ExitStack() as displays:
        for name in ("inviter", "responder"):
            folder = stage / name
            folder.mkdir()
            env, profile = profile_environment(folder)
            env = display_environment(args, folder, displays, env, name)
            peers.append((folder, env, profile))
        with ExitStack() as apps:
            screens = [apps.enter_context(isolated_app(args, folder, env, "pair"))
                       for folder, env, _ in peers]
            before = [wait_for_records(profile, args.timeout) for _, _, profile in peers]
            for screen in screens:
                find_manual_sync(args, screen)
                until(lambda: accent_exists(args, screen, 400, 168), "the native sync setup action")
            visible_grants = pair(args, *screens)
            if visible_grants[0] == visible_grants[1]:
                raise RuntimeError("The two devices did not display distinct peer fingerprints.")

        committed = [setup_proof(profile) for _, _, profile in peers]
        if committed[0][0] != committed[1][0] or committed[0][1] == committed[1][1]:
            raise RuntimeError("Pairing did not establish one workspace with two independent vaults.")
        for index, (folder, env, profile) in enumerate(peers):
            with isolated_app(args, folder, env, "reopen") as reopened:
                find_manual_sync(args, reopened)
                check(args, reopened, "Unlock sync", region=PROMPT)
                enter_passphrase(args, reopened, PASSPHRASE)
                if visible_peer(args, reopened) != visible_grants[index]:
                    raise RuntimeError("The original peer fingerprint changed after restart.")
            if setup_proof(profile) != committed[index] or records(profile) != before[index]:
                raise RuntimeError("Pairing or restart changed the saved vault or workspace.")

    return {"fresh_synthetic_profiles": 2, "matching_comparison_codes": True,
            "own_approval_rejected": True, "reciprocal_approvals_saved": True,
            "one_sync_workspace_two_vaults": True, "peer_fingerprints_reopened": True,
            "workspace_records_unchanged": True, "journal_integrity": "ok"}


def main():
    args = probe_arguments(__doc__)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="easy-native-pairing-") as scratch:
        checks = run(args, Path(scratch))
    report = {"source_revision": args.revision, "executable_sha256": sha256(args.binary),
              "aot_sha256": sha256(args.binary.parent / "lib" / "libapp.so"),
              "viewport": VIEWPORT, "elapsed_seconds": round(time.monotonic() - started, 2),
              "checks": checks}
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
