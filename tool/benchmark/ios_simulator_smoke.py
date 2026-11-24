#!/usr/bin/env python3
"""Launch the built app on a disposable iPhone simulator and check its empty store."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import time
import uuid

from initial_workspace_probe import read_pending_workspace


def simctl(*arguments, check=True, timeout=30):
    return subprocess.run(
        ["xcrun", "simctl", *arguments], check=check, text=True,
        stdout=subprocess.PIPE, timeout=timeout,
    )


def select_iphone(inventory, sdk_version):
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + sdk_version.replace(".", "-")
    phones = [
        device for device in inventory["devices"].get(runtime, [])
        if device["name"].startswith("iPhone ")
        and device.get("isAvailable") is True
        and device.get("state") == "Shutdown"
    ]
    if not phones:
        raise RuntimeError(f"No available shutdown iPhone simulator for iOS {sdk_version}.")
    selected = min(
        phones,
        key=lambda item: (item["name"] != "iPhone 17", item["name"], item["udid"]),
    )
    return selected["name"], selected["deviceTypeIdentifier"], runtime


def wait_for_workspace(database, pid):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        os.kill(pid, 0)
        if database.is_file():
            try:
                if read_pending_workspace(database):
                    return
            except sqlite3.OperationalError:
                # The schema and first revision may still be getting committed.
                pass
        time.sleep(0.25)
    raise RuntimeError("Easy did not initialize its private workspace within 45 seconds.")


def check_ios_launch(bundle, screenshot):
    with (bundle / "Info.plist").open("rb") as metadata:
        bundle_id = plistlib.load(metadata)["CFBundleIdentifier"]
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
        text=True, timeout=30,
    ).strip()
    inventory = json.loads(simctl("list", "--json", "devices", "available").stdout)
    name, device_type, runtime = select_iphone(inventory, sdk)
    created = simctl("create", "Easy first launch", device_type, runtime, timeout=90).stdout
    device_id = str(uuid.UUID(created.strip()))
    print(f"Starting {name} with iOS {sdk}.", flush=True)
    try:
        print(simctl("bootstatus", device_id, "-b", timeout=300).stdout.strip(), flush=True)
        print("Installing the built iOS simulator app.", flush=True)
        simctl("install", device_id, str(bundle), timeout=120)
        installed = simctl("get_app_container", device_id, bundle_id, "data", timeout=90)
        container = Path(installed.stdout.strip())
        if not container.is_absolute() or not container.is_dir():
            raise RuntimeError("The installed app has no valid simulator data container.")
        database = container / "Library" / "Application Support" / "easy" / "workspace.sqlite3"
        if database.exists():
            raise RuntimeError("The app's simulator container already has a workspace.")

        launched = simctl("launch", device_id, bundle_id, timeout=90).stdout.strip()
        match = re.fullmatch(rf"{re.escape(bundle_id)}:\s+([1-9][0-9]*)", launched)
        if match is None:
            raise RuntimeError("CoreSimulator did not report a PID for the launched app.")
        pid = int(match[1])
        wait_for_workspace(database, pid)
        print("Verified the app's empty private workspace and pending setup state.", flush=True)

        # The SQLite commit precedes the first frame of the setup screen.
        time.sleep(1)
        screenshot.parent.mkdir(parents=True, exist_ok=True)
        simctl("io", device_id, "screenshot", "--type=png", str(screenshot), timeout=60)
        os.kill(pid, 0)
        with screenshot.open("rb") as captured:
            if captured.read(8) != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError("CoreSimulator did not write a valid PNG screenshot.")
    finally:
        for command in ("shutdown", "delete"):
            try:
                simctl(command, device_id, check=False, timeout=30)
            except subprocess.TimeoutExpired:
                print(f"CoreSimulator {command} timed out during cleanup.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("screenshot", type=Path)
    arguments = parser.parse_args()
    check_ios_launch(arguments.bundle.resolve(), arguments.screenshot.resolve())
