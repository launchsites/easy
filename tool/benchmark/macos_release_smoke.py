#!/usr/bin/env python3
"""Verify a locally signed macOS release in its own hosted runner sandbox."""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import re
import sqlite3
import stat
import subprocess
import tempfile
import time

from initial_workspace_probe import read_pending_workspace


def sign_copy(bundle, entitlements, scratch):
    copied = scratch / bundle.name
    subprocess.run(["/usr/bin/ditto", bundle, copied], check=True, timeout=45)
    frameworks = copied / "Contents" / "Frameworks"
    nested_code = [
        entry for entry in frameworks.rglob("*")
        if entry.suffix in {".dylib", ".framework", ".xpc", ".appex", ".app"}
        and not entry.is_symlink()
    ]
    sign = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none"]
    for component in sorted(nested_code, key=lambda entry: len(entry.parts), reverse=True):
        subprocess.run([*sign, component], check=True, timeout=30)
    subprocess.run([*sign, "--entitlements", entitlements, copied], check=True, timeout=45)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", copied], check=True, timeout=30)

    extracted = scratch / "verified-entitlements.plist"
    subprocess.run(
        ["/usr/bin/codesign", "--display", "--entitlements", extracted, "--xml", copied],
        check=True, timeout=20,
    )
    expected = plistlib.loads(entitlements.read_bytes())
    try:
        embedded = plistlib.loads(extracted.read_bytes())
    except (FileNotFoundError, plistlib.InvalidFileException) as error:
        raise RuntimeError("macOS codesign did not extract the release entitlements as XML.") from error
    if expected.get("com.apple.security.app-sandbox") is not True or embedded != expected:
        raise RuntimeError("The runner-local macOS copy did not preserve the release sandbox entitlements.")
    return copied


def wait_for_workspace(app, database, container):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if app.poll() is not None:
            raise RuntimeError(f"The macOS release exited before verification with status {app.returncode}.")
        try:
            metadata = database.lstat()
        except FileNotFoundError:
            time.sleep(0.25)
            continue
        app_root = container.lstat()
        if (
            metadata.st_uid != os.geteuid()
            or not stat.S_ISREG(metadata.st_mode)
            or app_root.st_uid != os.geteuid()
            or not stat.S_ISDIR(app_root.st_mode)
            or not database.resolve().is_relative_to(container.resolve())
        ):
            raise RuntimeError("The app workspace is outside its fresh owned macOS sandbox container.")
        try:
            if read_pending_workspace(database):
                return
        except sqlite3.OperationalError:
            # The app may still be committing its first SQLite revision.
            pass
        time.sleep(0.25)
    raise RuntimeError("The macOS release did not initialize its sandboxed workspace within 120 seconds.")


def check_release(bundle, entitlements, scratch):
    metadata = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
    identifier = metadata["CFBundleIdentifier"]
    executable = metadata["CFBundleExecutable"]
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier):
        raise RuntimeError("The macOS release has an unexpected bundle identifier.")
    if not executable or Path(executable).name != executable or executable in {".", ".."}:
        raise RuntimeError("The macOS release has an unexpected bundle executable.")

    container = Path.home() / "Library" / "Containers" / identifier
    try:
        container.lstat()
    except FileNotFoundError:
        pass
    else:
        raise RuntimeError("The selected macOS bundle already has a container on this runner.")
    database = container / "Data" / "Library" / "Application Support" / identifier / "easy" / "workspace.sqlite3"
    signed = sign_copy(bundle, entitlements, scratch)

    log_path = scratch / "macos-release.log"
    with log_path.open("w") as log:
        app = subprocess.Popen(
            [signed / "Contents" / "MacOS" / executable], cwd=scratch,
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            wait_for_workspace(app, database, container)
            os.kill(app.pid, 0)
            print(f"Verified the sandboxed macOS release's empty private workspace with live PID {app.pid}.")
        except (OSError, RuntimeError, sqlite3.DatabaseError):
            print("\n".join(log_path.read_text(errors="replace").splitlines()[-25:]), flush=True)
            raise
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("entitlements", type=Path)
    arguments = parser.parse_args()
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("Use a disposable GitHub-hosted macOS runner.")
    with tempfile.TemporaryDirectory(prefix="easy-macos-smoke.", dir=os.environ["RUNNER_TEMP"]) as location:
        check_release(arguments.bundle.resolve(), arguments.entitlements.resolve(), Path(location))
