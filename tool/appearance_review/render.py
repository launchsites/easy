#!/usr/bin/env python3
"""Build and capture the native Easy appearance review from a frozen source tree."""

import argparse
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tarfile
import tempfile
import time


SOURCE = "d8e901823b64bca562024cc222d68dfef926a072"
ROOT = Path(__file__).resolve().parents[2]
DESKTOP = (1440, 900)
PHONE = (390, 844)

COLORS = {
    "appearance/appearance.dart": (
        "faf9f5", "242922", "686d63", "e7e7df", "426651", "171c18",
        "c2c9bd", "fffefa", "e7eee4", "222923", "f5f7f1", "343d34",
        "2a342b", "f0f5ec", "dcead9", "293e2f", "f1f1eb", "808a7e",
    ),
    "workspace_chrome.dart": (
        "dcead9", "f5f7f1", "343d34", "3d473c", "e3ebdf", "283d31",
        "323b33", "a7b0a4", "2a342b", "d0dfd1", "f0f5ec",
    ),
    "list_pages.dart": ("f1f0e9", "899083"),
}

PALETTES = {
    "warm-paper": {
        "appearance/appearance.dart": (
            "fffcf6", "292521", "675e54", "e8ded2", "4d6452", "231f1c",
            "d0c4b7", "fffefb", "e9eee4", "2d2824", "faf3e8", "493d36",
            "39302a", "fff6ec", "eee1ce", "34493b", "f6efe5", "83766a",
        ),
        "workspace_chrome.dart": (
            "eee1ce", "faf3e8", "493d36", "52453a", "f1e3ca", "302a25",
            "433931", "b7a696", "39302a", "eadcc9", "fff6ec",
        ),
        "list_pages.dart": ("f6efe5", "83766a"),
    },
    "cool-white": {
        "appearance/appearance.dart": (
            "f8fbff", "1e2636", "526279", "dbe4ef", "385d98", "171d27",
            "c1cee2", "ffffff", "e6effe", "222a37", "f1f6fd", "38455b",
            "2a374b", "f0f6ff", "cfe0f8", "253e67", "edf3fa", "697b95",
        ),
        "workspace_chrome.dart": (
            "cfe0f8", "f1f6fd", "38455b", "42526a", "dce9ff", "243c63",
            "354257", "a8bad1", "2a374b", "d4e4fd", "f0f6ff",
        ),
        "list_pages.dart": ("edf3fa", "697b95"),
    },
}

STYLES = {
    "ui_theme.dart": {
        "Radius.circular(16)": ("Radius.circular(20)", "Radius.circular(14)"),
        "Radius.circular(11)": ("Radius.circular(13)", "Radius.circular(9)"),
        "fontSize: mobile ? 44 : 54": (
            "fontSize: mobile ? 45 : 58",
            "fontSize: mobile ? 42 : 50",
        ),
        "letterSpacing: mobile ? -2.5 : -3.3": (
            "letterSpacing: mobile ? -2.1 : -2.8",
            "letterSpacing: mobile ? -1.8 : -2.6",
        ),
    },
    "workspace_chrome.dart": {
        "BorderRadius.circular(19)": (
            "BorderRadius.circular(25)",
            "BorderRadius.circular(15)",
        ),
    },
    "list_pages.dart": {
        "availableWidth - 1030": ("availableWidth - 970", "availableWidth - 1100"),
        "constraints: const BoxConstraints(minHeight: 58)": (
            "constraints: const BoxConstraints(minHeight: 62)",
            "constraints: const BoxConstraints(minHeight: 52)",
        ),
        "fromSTEB(8, 9, 10, 9)": ("fromSTEB(8, 10, 10, 10)", "fromSTEB(8, 6, 10, 6)"),
        "shortLandscape ? 12 : (mobile ? 25 : 42)": (
            "shortLandscape ? 12 : (mobile ? 25 : 49)",
            "shortLandscape ? 12 : (mobile ? 25 : 36)",
        ),
    },
    "mobile_home.dart": {
        "gap = SizedBox(height: compact ? 15 : 27)": (
            "gap = SizedBox(height: compact ? 15 : 29)",
            "gap = SizedBox(height: compact ? 15 : 21)",
        ),
        "block(SizedBox(height: compact ? 16 : 32))": (
            "block(SizedBox(height: compact ? 16 : 34))",
            "block(SizedBox(height: compact ? 16 : 26))",
        ),
        "letterSpacing: -fontSize * .051": (
            "letterSpacing: -fontSize * .04",
            "letterSpacing: -fontSize * .045",
        ),
    },
}


def build_snapshot(args, source_dir):
    git = ["git"]
    if args.git_dir:
        git += ["--git-dir", str(args.git_dir)]
    with subprocess.Popen(
        [*git, "archive", SOURCE], cwd=ROOT, stdout=subprocess.PIPE,
    ) as archive:
        with tarfile.open(fileobj=archive.stdout, mode="r|") as contents:
            contents.extractall(source_dir, filter="data")
        if archive.wait(timeout=30) != 0:
            raise RuntimeError(f"Cannot archive the frozen source {SOURCE}.")

    variant_index = tuple(PALETTES).index(args.variant)
    for relative, originals in COLORS.items():
        path = source_dir / "lib" / relative
        content = path.read_text()
        for original, replacement in zip(originals, PALETTES[args.variant][relative], strict=True):
            content, count = re.subn(
                f"(?i)0xff{original}",
                f"0xff{replacement}",
                content,
            )
            if count == 0:
                raise RuntimeError(f"Expected color {original} in {relative}.")
        path.write_text(content)
    for relative, styles in STYLES.items():
        path = source_dir / "lib" / relative
        content = path.read_text()
        for original, replacements in styles.items():
            if content.count(original) != 1:
                raise RuntimeError(f"Expected one {original!r} in {relative}.")
            content = content.replace(original, replacements[variant_index])
        path.write_text(content)

    flutter = [args.flutter]
    subprocess.run([*flutter, "pub", "get", "--offline"], cwd=source_dir, check=True)
    subprocess.run(
        [*flutter, "build", "linux", "--release", "--no-pub"],
        cwd=source_dir,
        check=True,
    )
    return source_dir / "build/linux/x64/release/bundle/easy"


def isolated_environment(directory, args):
    env = os.environ.copy()
    for variable in ("WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY"):
        env.pop(variable, None)
    for name in ("DATA", "CONFIG", "CACHE", "RUNTIME", "STATE"):
        path = directory / name.lower()
        path.mkdir(mode=0o700)
        env[f"XDG_{name}_HOME" if name != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(path)
    env["GDK_BACKEND"] = "x11"
    env["LIBGL_ALWAYS_SOFTWARE"] = "1"
    env["OMP_THREAD_LIMIT"] = "1"
    if args.extra_libraries:
        libraries = [str(args.extra_libraries), env.get("LD_LIBRARY_PATH")]
        env["LD_LIBRARY_PATH"] = os.pathsep.join(filter(None, libraries))
    return env


class NativeWindow:
    def __init__(self, identifier, env, args, directory):
        self.identifier = identifier
        self.env = env
        self.args = args
        self.directory = directory

    def send(self, *arguments):
        subprocess.run(
            [self.args.xdotool, *map(str, arguments)], env=self.env,
            capture_output=True, check=True, timeout=10,
        )

    def resize(self, size):
        self.send("windowsize", "--sync", self.identifier, *size)

    def tap(self, x, y):
        self.send("mousemove", "--window", self.identifier, x, y, "click", 1)

    def capture(self, name, size, expected):
        self.send("mousemove", 1520, 1000)
        target = self.directory / f"{name}.png"
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            time.sleep(0.25)
            subprocess.run(
                [self.args.capture, "-window", self.identifier, "-strip", str(target)],
                env=self.env, capture_output=True, check=True, timeout=8,
            )
            dimensions = subprocess.check_output(
                [self.args.identify, "-format", "%w %h", str(target)], text=True, timeout=8,
            )
            if tuple(map(int, dimensions.split())) != size:
                continue
            transcript = " ".join(self.ocr(target, "txt").casefold().split())
            if all(label in transcript for label in expected):
                return target
        raise RuntimeError(f"The {name} screenshot did not match {size} and {expected}.")

    def ocr(self, image, format):
        return subprocess.check_output(
            [self.args.ocr, str(image), "stdout", "--psm", "11", format],
            env=self.env, text=True, stderr=subprocess.DEVNULL, timeout=10,
        )

    def tap_word(self, screenshot, word):
        for line in self.ocr(screenshot, "tsv").splitlines()[1:]:
            columns = line.split("\t")
            if len(columns) == 12 and columns[-1].casefold() == word.casefold():
                left, top, width, height = map(int, columns[6:10])
                self.tap(left + width // 2, top + height // 2)
                return
        raise RuntimeError(f"Could not locate {word!r} in {screenshot.name}.")


def live_window(pid, env, xdotool):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        result = subprocess.run(
            [xdotool, "search", "--onlyvisible", "--pid", str(pid)],
            env=env, capture_output=True, text=True, timeout=5,
        )
        windows = result.stdout.split()
        if result.returncode == 0 and windows:
            return windows[-1]
        time.sleep(0.15)
    raise RuntimeError("The native Easy window did not appear.")


def stop(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=6)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=6)


def capture_routes(app, directory, args):
    env = isolated_environment(directory, args)
    with (directory / "xvfb.log").open("wb") as xlog:
        display = subprocess.Popen(
            [
                args.xvfb, "-displayfd", "1", "-screen", "0", "1600x1060x24",
                "-nolisten", "tcp", "-ac", "-noreset",
            ],
            env=env, stdout=subprocess.PIPE, stderr=xlog, text=True,
        )
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(display.stdout, selectors.EVENT_READ)
                if not ready.select(timeout=12):
                    raise RuntimeError("The isolated display did not start.")
                display_number = display.stdout.readline().strip()
                if not display_number.isdigit():
                    raise RuntimeError("The isolated display returned no display number.")
            env["DISPLAY"] = f":{display_number}"
            with (directory / "easy.log").open("wb") as log:
                process = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log)
                try:
                    screen = NativeWindow(
                        live_window(process.pid, env, args.xdotool), env, args, directory,
                    )
                    screen.send("windowmove", screen.identifier, 0, 0)
                    screen.resize(DESKTOP)
                    screen.capture("ready", DESKTOP, ("studio review", "today"))
                    screen.tap(76, 195)
                    tasks = screen.capture(
                        "tasks", DESKTOP, ("tasks", "send venue options", "review chapter notes"),
                    )
                    screen.tap(76, 101)
                    screen.resize(PHONE)
                    home = screen.capture("home", PHONE, ("note to self", "tasks due today"))
                    screen.tap_word(home, "Mode")
                    menu = screen.capture("menu", PHONE, ("settings", "gym"))
                    screen.tap_word(menu, "Gym")
                    gym = screen.capture("gym", PHONE, ("gym", "workout", "bench press"))
                    return tasks, home, gym
                finally:
                    stop(process)
        finally:
            stop(display)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variant", choices=PALETTES)
    parser.add_argument("output", type=Path)
    parser.add_argument("--git-dir", type=Path)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--capture", default="import")
    parser.add_argument("--identify", default="identify")
    parser.add_argument("--ocr", default="tesseract")
    parser.add_argument("--extra-libraries", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix=f"easy-{args.variant}-") as temporary:
        directory = Path(temporary)
        source = directory / "source"
        source.mkdir()
        app = build_snapshot(args, source)
        screenshots = capture_routes(app, directory, args)
        args.output.mkdir(parents=True, exist_ok=True)
        for screenshot in screenshots:
            result = args.output / f"{args.variant}-{screenshot.name}"
            shutil.copyfile(screenshot, result)
            print(result)


if __name__ == "__main__":
    main()
