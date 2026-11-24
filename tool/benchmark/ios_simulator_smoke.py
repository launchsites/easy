#!/usr/bin/env python3
"""Launch the built app on a disposable iPhone simulator and check its empty store."""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import sqlite3
import subprocess
import time
import uuid

from initial_workspace_probe import read_pending_workspace


def xcrun_command():
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        return ["/usr/bin/arch", "-arm64e", "xcrun"]
    return ["xcrun"]


def simctl(*arguments, check=True, timeout=30):
    return subprocess.run(
        [*xcrun_command(), "simctl", *arguments], check=check, text=True,
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


def reported_pid(launch, bundle_id):
    output = launch.communicate()[0].strip()
    match = re.search(rf"^{re.escape(bundle_id)}:\s+([1-9][0-9]*)$", output, re.MULTILINE)
    if launch.returncode != 0 or match is None:
        raise RuntimeError(f"CoreSimulator could not confirm app launch. {output}")
    return int(match[1])


def wait_for_workspace(database, launch, bundle_id):
    deadline = time.monotonic() + 150
    pid = None
    while time.monotonic() < deadline:
        if pid is None and launch.poll() is not None:
            pid = reported_pid(launch, bundle_id)
        if pid is not None:
            os.kill(pid, 0)
        if database.is_file():
            try:
                if read_pending_workspace(database):
                    return pid
            except sqlite3.OperationalError:
                # The schema and first revision may still be getting committed.
                pass
        time.sleep(0.25)
    raise RuntimeError("Easy did not initialize its private workspace within 150 seconds.")


def simulator_pid(device_id, bundle_id):
    processes = simctl("spawn", device_id, "launchctl", "list", timeout=25).stdout
    label = f"UIKitApplication:{bundle_id}["
    for line in processes.splitlines():
        columns = line.split(maxsplit=2)
        if len(columns) == 3 and columns[2].startswith(label) and columns[0].isdigit():
            return int(columns[0])
    raise RuntimeError("The simulator did not report a running app process.")


def print_launch_diagnostics(device_id, bundle_id):
    if platform.system() == "Darwin":
        predicate = 'process == "CoreSimulatorService" OR process == "simdiskimaged" OR process == "launchd_sim"'
        try:
            host_log = subprocess.run(
                ["/usr/bin/log", "show", "--last", "4m", "--style", "compact", "--predicate", predicate],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=25,
            )
            print("Simulator host diagnostic", flush=True)
            print("\n".join(host_log.stdout.splitlines()[-35:]), flush=True)
        except subprocess.TimeoutExpired:
            print("Simulator host diagnostic timed out.", flush=True)

    predicate = f'process == "Runner" OR eventMessage CONTAINS[c] "{bundle_id}"'
    for commands, timeout in (
        (("spawn", device_id, "log", "show", "--last", "4m", "--style", "compact", "--predicate", predicate), 30),
        (("launch", device_id, "com.apple.Preferences"), 30),
    ):
        try:
            result = simctl(*commands, check=False, timeout=timeout)
            print(f"CoreSimulator {commands[0]} diagnostic (exit {result.returncode}):", flush=True)
            print("\n".join(result.stdout.splitlines()[-35:]), flush=True)
        except subprocess.TimeoutExpired:
            print(f"CoreSimulator {commands[0]} diagnostic timed out.", flush=True)


def verify_launch(device_id, bundle_id, database, screenshot):
    launch = subprocess.Popen(
        [*xcrun_command(), "simctl", "launch", device_id, bundle_id], stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True,
    )
    try:
        pid = wait_for_workspace(database, launch, bundle_id)
        if pid is None:
            pid = reported_pid(launch, bundle_id) if launch.poll() is not None else simulator_pid(device_id, bundle_id)
        print("Verified the app's empty private workspace and pending setup state.", flush=True)

        # The SQLite commit precedes the first frame of the setup screen.
        time.sleep(1)
        screenshot.parent.mkdir(parents=True, exist_ok=True)
        simctl("io", device_id, "screenshot", "--type=png", str(screenshot), timeout=60)
        os.kill(pid, 0)
        with screenshot.open("rb") as captured:
            if captured.read(8) != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError("CoreSimulator did not write a valid PNG screenshot.")
    except (OSError, RuntimeError, sqlite3.DatabaseError, subprocess.SubprocessError):
        print_launch_diagnostics(device_id, bundle_id)
        raise
    finally:
        if launch.poll() is None:
            launch.terminate()
            try:
                launch.wait(timeout=5)
            except subprocess.TimeoutExpired:
                launch.kill()
                launch.wait()
        launch.stdout.close()


def check_ios_launch(bundle, screenshot):
    with (bundle / "Info.plist").open("rb") as metadata:
        bundle_id = plistlib.load(metadata)["CFBundleIdentifier"]
    sdk = subprocess.check_output(
        [*xcrun_command(), "--sdk", "iphonesimulator", "--show-sdk-version"],
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
        try:
            simctl("install", device_id, str(bundle), timeout=120)
            installed = simctl("get_app_container", device_id, bundle_id, "data", timeout=90)
        except subprocess.SubprocessError:
            print_launch_diagnostics(device_id, bundle_id)
            raise
        container = Path(installed.stdout.strip())
        if not container.is_absolute() or not container.is_dir():
            raise RuntimeError("The installed app has no valid simulator data container.")
        database = container / "Library" / "Application Support" / "easy" / "workspace.sqlite3"
        if database.exists():
            raise RuntimeError("The app's simulator container already has a workspace.")

        verify_launch(device_id, bundle_id, database, screenshot)
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
