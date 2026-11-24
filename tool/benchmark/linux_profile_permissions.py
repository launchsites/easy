#!/usr/bin/env python3
"""Check Linux profile permissions using synthetic directories and a release bundle."""

import argparse
from contextlib import ExitStack, closing
from datetime import date
import json
import os
from pathlib import Path
import select
import sqlite3
import stat
import subprocess
import tempfile

from local_inference import sha256
from native_ui_fixture import workspace
from native_ui_soak import wait_for_workspace
from native_workspace_scale import stop


APP_ID = "app.launchsites.easy"
PUBLIC_DIRECTORY = 0o755
PUBLIC_FILE = 0o644
PRIVATE_DIRECTORY = 0o700
PRIVATE_FILE = 0o600


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def require_mode(path, expected):
    actual = mode(path)
    if actual != expected:
        raise RuntimeError(f"{path.name} mode {actual:04o}, expected {expected:04o}")
    return f"{actual:04o}"


def directory(path, permissions=PUBLIC_DIRECTORY):
    path.mkdir()
    path.chmod(permissions)
    return path


def owned_file(path, payload):
    path.write_text(payload)
    path.chmod(PUBLIC_FILE)
    return path


def helper_checks(root, build_root, compiler):
    driver = root / "driver.cc"
    driver.write_text(
        '#include "profile_permissions.h"\n'
        'int main(int argc, char** argv) {\n'
        '  if (argc != 2) return 1;\n'
        f'  protect_easy_profile(argv[1], "{APP_ID}", "easy");\n'
        '  return 0;\n'
        '}\n'
    )
    runner = build_root / "linux" / "runner"
    executable = root / "driver"
    subprocess.run([
        compiler, "-std=c++14", "-Wall", "-Werror", "-I", runner,
        driver, runner / "profile_permissions.cc", "-o", executable,
    ], check=True, timeout=60)

    def protect(data):
        subprocess.run([executable, data], check=True, timeout=5)

    parent = directory(root / "real-data")
    exact = directory(parent / APP_ID, 0o555)
    alias = root / "data-link"
    alias.symlink_to(parent, target_is_directory=True)
    protect(alias)
    require_mode(exact, 0o555)
    protect(parent)
    require_mode(exact, 0o500)
    exact.chmod(PRIVATE_DIRECTORY)

    data = directory(root / "profile-link-data")
    target = directory(root / "profile-link-target")
    (data / APP_ID).symlink_to(target, target_is_directory=True)
    fallback = directory(data / "easy")
    unrelated = directory(fallback / "easy")
    owned_file(unrelated / "workspace.sqlite3", "synthetic file")
    protect(data)
    require_mode(target, PUBLIC_DIRECTORY)
    require_mode(unrelated, PUBLIC_DIRECTORY)

    data = directory(root / "legacy-data")
    legacy = directory(data / "easy")
    selected = directory(legacy / "easy")
    preferences = owned_file(legacy / "shared_preferences.json", "{}")
    sibling = owned_file(legacy / "unrelated-export", "synthetic export")
    protect(data)
    require_mode(selected, PUBLIC_DIRECTORY)
    require_mode(preferences, PUBLIC_FILE)
    database = selected / "workspace.sqlite3"
    with closing(sqlite3.connect(database)) as connection:
        connection.execute("PRAGMA application_id = 0x45535931")
        connection.commit()
    preferences.unlink()
    preferences.hardlink_to(sibling)
    protect(data)
    require_mode(selected, PRIVATE_DIRECTORY)
    require_mode(sibling, PUBLIC_FILE)
    require_mode(preferences, PUBLIC_FILE)
    preferences.unlink()
    preferences.symlink_to(sibling)
    protect(data)
    require_mode(sibling, PUBLIC_FILE)
    preferences.unlink()
    owned_file(preferences, "{}")
    protect(data)
    require_mode(selected, PRIVATE_DIRECTORY)
    require_mode(preferences, PRIVATE_FILE)
    require_mode(legacy, PUBLIC_DIRECTORY)
    require_mode(sibling, PUBLIC_FILE)
    return {
        "symlink_ancestors_and_profile_left_untouched": True,
        "owner_permissions_preserved": True,
        "verified_legacy_directory_and_preferences_tightened": True,
        "linked_preference_files_left_untouched": True,
        "unrelated_files_left_untouched": True,
    }


def run_bundle(args, root, display, *, existing):
    variant = directory(root / ("existing" if existing else "new"))
    data = directory(variant / "data")
    profile = data / APP_ID
    sibling = directory(data / "unrelated-profile")
    unrelated_export = owned_file(variant / "user-export", "synthetic export")
    if existing:
        directory(profile)
        input_text = json.dumps({
            "easy.workspace.v1": json.dumps(workspace(date.today(), 0, 1, 1)),
        })
        legacy_preferences = owned_file(profile / "shared_preferences.json", input_text)
    environment = os.environ.copy()
    environment.update(
        DISPLAY=display,
        LIBGL_ALWAYS_SOFTWARE="1",
        XDG_DATA_HOME=str(data),
        XDG_CONFIG_HOME=str(directory(variant / "config")),
        XDG_CACHE_HOME=str(directory(variant / "cache")),
        XDG_RUNTIME_DIR=str(directory(variant / "runtime", PRIVATE_DIRECTORY)),
        DBUS_SESSION_BUS_ADDRESS=f"unix:path={variant / 'fixture-no-session.sock'}",
    )
    with ExitStack() as stack:
        log = stack.enter_context((variant / "app.log").open("wb"))
        app = subprocess.Popen([args.binary], env=environment, umask=0o022,
                               stdout=log, stderr=log)
        stack.callback(stop, app)
        database = profile / "easy" / "workspace.sqlite3"
        evidence = wait_for_workspace(database, timeout=40)
        if app.poll() is not None or evidence["quick_check"] != "ok":
            raise RuntimeError("The disposable workspace did not open cleanly.")
        if evidence["counts"]["tasks"] != int(existing):
            raise RuntimeError("Existing synthetic records did not survive reopening.")
        modes = {
            "xdg_parent": require_mode(data, PUBLIC_DIRECTORY),
            "profile": require_mode(profile, PRIVATE_DIRECTORY),
            "workspace_directory": require_mode(database.parent, PRIVATE_DIRECTORY),
            "database": require_mode(database, PRIVATE_FILE),
            "database_wal": require_mode(database.with_name(database.name + "-wal"), PRIVATE_FILE),
            "unrelated_profile": require_mode(sibling, PUBLIC_DIRECTORY),
            "unrelated_export": require_mode(unrelated_export, PUBLIC_FILE),
        }
        if existing:
            if legacy_preferences.read_text() != input_text:
                raise RuntimeError("The older preference snapshot changed during migration.")
            modes["older_preferences_under_private_profile"] = require_mode(legacy_preferences, PUBLIC_FILE)
    return {"modes": modes, "workspace": evidence}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--source", default=Path(__file__).resolve().parents[2], type=Path)
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--compiler", default="g++")
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    library = args.binary.parent / "lib" / "libapp.so"
    with tempfile.TemporaryDirectory(prefix="easy-profile-permissions-") as scratch, ExitStack() as stack:
        root = Path(scratch)
        helper = helper_checks(root, args.source, args.compiler)
        log = stack.enter_context((root / "xvfb.log").open("wb"))
        xvfb = subprocess.Popen([args.xvfb, "-displayfd", "1", "-screen", "0", "1280x900x24",
                                 "-nolisten", "tcp"], stdout=subprocess.PIPE, stderr=log)
        stack.callback(stop, xvfb)
        if not select.select([xvfb.stdout], [], [], 12)[0]:
            raise RuntimeError("The isolated X11 display did not start.")
        number = xvfb.stdout.readline().strip().decode("ascii")
        if not number.isdecimal():
            raise RuntimeError("The isolated X11 display returned an invalid identifier.")
        display = f":{number}"
        print(json.dumps({
            "executable_sha256": sha256(args.binary),
            "aot_library_sha256": sha256(library),
            "parent_umask": "0022",
            "native_helper": helper,
            "new_profile": run_bundle(args, root, display, existing=False),
            "existing_profile": run_bundle(args, root, display, existing=True),
        }, indent=2))


if __name__ == "__main__":
    main()
