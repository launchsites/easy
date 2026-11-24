#!/usr/bin/env python3
"""Run a development release on a disposable AOSP phone and verify first launch."""

import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time

from initial_workspace_probe import read_pending_workspace


SERIAL = "emulator-5554"
SYSTEM_IMAGE = "system-images;android-36;default;x86_64"
PNG_HEADER = b"\x89PNG\r\n\x1a\n"


def adb_run(adb, *arguments, check=True, timeout=10):
    return subprocess.run(
        [adb, "-s", SERIAL, *arguments], check=check, timeout=timeout,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


def wait_on_device(emulator, probe, description, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if emulator.poll() is not None:
            raise RuntimeError(f"The Android emulator exited while waiting for {description}.")
        try:
            if probe():
                return
        except subprocess.TimeoutExpired:
            # ADB can briefly lose transport while the emulator boots or roots.
            pass
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for {description}.")


def get_prop(adb, name):
    return adb_run(adb, "shell", "getprop", name, check=False, timeout=5).stdout.strip()


def root_test_device(adb, emulator):
    wait_on_device(emulator, lambda: get_prop(adb, "sys.boot_completed") == "1", "Android boot", 240)
    is_emulator = "1" in {get_prop(adb, "ro.boot.qemu"), get_prop(adb, "ro.kernel.qemu")}
    if (
        not is_emulator
        or get_prop(adb, "ro.build.version.sdk") != "36"
        or get_prop(adb, "ro.product.cpu.abi") != "x86_64"
        or get_prop(adb, "ro.build.type") not in {"eng", "userdebug"}
    ):
        raise RuntimeError("The selected device is not the disposable x86-64 AOSP API 36 emulator.")
    adb_run(adb, "root")
    wait_on_device(
        emulator,
        lambda: adb_run(adb, "shell", "id", "-u", check=False, timeout=5).stdout.strip() == "0",
        "the rooted AOSP test shell",
        30,
    )


def check_workspace_snapshot(adb, remote, snapshot):
    if adb_run(adb, "shell", "test", "-f", remote, check=False).returncode:
        return False
    for suffix in ("-shm", "-wal", ""):
        Path(f"{snapshot}{suffix}").unlink(missing_ok=True)
    adb_run(adb, "pull", remote, str(snapshot))
    if not adb_run(adb, "shell", "test", "-f", f"{remote}-wal", check=False).returncode:
        adb_run(adb, "pull", f"{remote}-wal", f"{snapshot}-wal")
    try:
        return read_pending_workspace(snapshot)
    except sqlite3.DatabaseError:
        # A copy made while the app commits its first revision can be incomplete.
        return False


def log_system_bar_appearance(adb):
    output = adb_run(adb, "shell", "dumpsys", "window", "displays", check=False)
    markers = ("mFocusedWindow=", "mLastAppearance=", "mLastStatusBarAppearanceRegions=",
               "mNavBarColorWindowCandidate=", "AppearanceRegion{")
    appearance = [line.strip() for line in output.stdout.splitlines() if any(mark in line for mark in markers)]
    print("Android focused window and system-bar appearance", flush=True)
    print("\n".join(appearance[:16]), flush=True)


def check_app_launch(adb, emulator, apk, package, screenshot, snapshot):
    adb_run(adb, "install", str(apk), timeout=60)
    resolved = adb_run(
        adb, "shell", "cmd", "package", "resolve-activity", "--brief",
        "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package,
    ).stdout.splitlines()
    launchers = [line.strip() for line in resolved if line.strip().startswith(f"{package}/")]
    if len(launchers) != 1:
        raise RuntimeError("Android did not resolve one launcher for the installed release.")
    launcher = launchers[0]
    adb_run(adb, "shell", "input", "keyevent", "82")
    adb_run(adb, "shell", "am", "start", "-W", "-n", launcher, timeout=45)

    remote = f"/data/user/0/{package}/files/easy/workspace.sqlite3"
    wait_on_device(
        emulator, lambda: check_workspace_snapshot(adb, remote, snapshot),
        "the app's empty private workspace and pending setup state", 60,
    )
    print("Verified the app's empty private workspace and pending setup state.", flush=True)

    # Allow the first setup frame and its system-bar appearance to settle.
    time.sleep(3)
    adb_run(adb, "shell", "pidof", package)
    log_system_bar_appearance(adb)
    pixels = subprocess.check_output([adb, "-s", SERIAL, "exec-out", "screencap", "-p"], timeout=15)
    if not pixels.startswith(PNG_HEADER):
        raise RuntimeError("The emulator did not return a PNG screenshot.")
    screenshot.parent.mkdir(parents=True, exist_ok=True)
    screenshot.write_bytes(pixels)
    return launcher


def run_probe(sdk, apk, screenshot, scratch, *, meal_recovery_replay=False):
    tools = sdk / "cmdline-tools" / "latest" / "bin"
    adb = sdk / "platform-tools" / "adb"
    package = subprocess.check_output(
        [tools / "apkanalyzer", "manifest", "application-id", apk], text=True, timeout=20,
    ).strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", package):
        raise RuntimeError("The development APK has an unexpected application ID.")
    connected = subprocess.check_output([adb, "devices"], timeout=15, text=True)
    if any(line.split()[0] == SERIAL for line in connected.splitlines() if line.split()):
        raise RuntimeError(f"The dedicated emulator serial {SERIAL} is already in use.")

    avd_home = scratch / "avd"
    avd_home.mkdir()
    environment = {**os.environ, "ANDROID_AVD_HOME": str(avd_home)}
    subprocess.run([
        tools / "avdmanager", "create", "avd", "--name", "easy-smoke",
        "--package", SYSTEM_IMAGE, "--device", "pixel_6",
    ], env=environment, input="no\n", text=True, check=True, timeout=60)

    log_path = scratch / "emulator.log"
    with log_path.open("w") as log:
        emulator = subprocess.Popen([
            sdk / "emulator" / "emulator", "-avd", "easy-smoke", "-port", "5554",
            "-accel", "on", "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
            "-gpu", "swiftshader", "-cores", "2", "-memory", "2048",
        ], env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            root_test_device(adb, emulator)
            launcher = check_app_launch(adb, emulator, apk, package, screenshot, scratch / "workspace.sqlite3")
            if meal_recovery_replay:
                from android_meal_recovery_smoke import check_meal_recovery

                report = check_meal_recovery(adb, emulator, package, launcher, scratch)
                print(json.dumps(report, sort_keys=True), flush=True)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            print("\n".join(log_path.read_text(errors="replace").splitlines()[-40:]), flush=True)
            raise
        finally:
            if emulator.poll() is None:
                emulator.terminate()
                try:
                    emulator.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    emulator.kill()
                    emulator.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("screenshot", type=Path)
    parser.add_argument("--meal-recovery-replay", action="store_true")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="easy-android-smoke.") as location:
        run_probe(
            Path(os.environ["ANDROID_HOME"]).resolve(), arguments.apk.resolve(),
            arguments.screenshot.resolve(), Path(location),
            meal_recovery_replay=arguments.meal_recovery_replay,
        )
