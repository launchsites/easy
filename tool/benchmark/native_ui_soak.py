#!/usr/bin/env python3
"""Exercise a disposable Easy profile repeatedly on a Linux X11 display."""

import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time
import zlib

from local_inference import host_details, host_text, sha256
from native_ui_trace import process_rss, send_input


VIEWPORTS = ((390, 844), (320, 568), (719, 860), (760, 860), (1280, 900))
PAGES = (
    ("Today", 101, r"\btoday\b"),
    ("Calendar", 148, r"\b(?:mon|tue|wed|thu|fri|sat|sun)\b"),
    ("Tasks", 195, r"\b(?:tasks|synthetic task)\b"),
    ("Notes", 242, r"\b(?:notes|synthetic reading note)\b"),
)


def visible_window(xdotool, *, env=None):
    windows = subprocess.check_output(
        [xdotool, "search", "--onlyvisible", "--name", "^Easy$"],
        env=env, text=True, timeout=15,
    ).splitlines()
    if len(windows) != 1:
        raise RuntimeError("Use an isolated display with one visible Easy window.")
    window = windows[0]
    pid = int(subprocess.check_output(
        [xdotool, "getwindowpid", window], env=env, text=True, timeout=15,
    ))
    return window, pid


def check_heading(window, scratch, expected, crop, x11_capture, tesseract):
    path = scratch / "heading.png"
    subprocess.run(
        [x11_capture, "-window", window, "-crop", crop, str(path)],
        capture_output=True, check=True, timeout=12,
    )
    transcript = subprocess.check_output(
        [tesseract, str(path), "stdout", "--psm", "11"],
        text=True, stderr=subprocess.DEVNULL, timeout=15,
        env={**os.environ, "OMP_THREAD_LIMIT": "1"},
    )
    return {
        "matched": bool(re.search(expected, transcript, re.IGNORECASE)),
        "screenshot_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def pixel_at(window, x, y, x11_capture):
    pixel = subprocess.run(
        [x11_capture, "-window", window, "-crop", f"1x1+{x}+{y}", "-depth", "8", "rgb:-"],
        capture_output=True, check=True, timeout=8,
    ).stdout
    return list(pixel) if len(pixel) == 3 else None


def wait_for_resize(window, wide, x11_capture, timeout=25):
    deadline = time.monotonic() + timeout
    pixel = None
    while time.monotonic() < deadline:
        pixel = pixel_at(window, 191, 101, x11_capture)
        if pixel is not None and (max(pixel) < 100 if wide else min(pixel) > 160):
            return
        time.sleep(0.15)
    expected = "desktop" if wide else "mobile"
    raise RuntimeError(f"The {expected} layout did not render after resize. Last probe RGB was {pixel}.")


def check_desktop_route(window, scratch, y, heading, args, timeout=5, heading_timeout=0):
    # Sample the selected surface away from the icon, title and pointer.
    deadline = time.monotonic() + timeout
    while True:
        pixel = pixel_at(window, 191, y, args.x11_capture)
        selected = pixel is not None and all(
            abs(actual - expected) <= 5 for actual, expected in zip(pixel, (42, 52, 43))
        )
        if selected or time.monotonic() >= deadline:
            break
        time.sleep(0.2)
    visible = check_visible_page(window, scratch, heading, args, timeout=heading_timeout)
    return {
        "selected": selected,
        "sidebar_pixel_rgb": pixel,
        "heading_visible": visible["matched"],
        "screenshot_sha256": visible["screenshot_sha256"],
    }


def check_visible_page(window, scratch, heading, args, crop="830x210+240+42", timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        checked = check_heading(
            window, scratch, heading, crop, args.x11_capture, args.tesseract,
        )
        if checked["matched"] or time.monotonic() >= deadline:
            return checked
        time.sleep(0.2)


def workspace_state(path, *, include_document=False):
    location = f"{path.resolve().as_uri()}?mode=ro"
    with closing(sqlite3.connect(location, uri=True, timeout=3)) as db:
        fields = {column[1] for column in db.execute("PRAGMA table_info(documents)")}
        storage = "documents.chunked" if "chunked" in fields else "0"
        record = db.execute(f"""
            SELECT revisions.revision, revisions.workspace, documents.body, {storage}
            FROM revisions JOIN documents ON documents.digest = revisions.workspace
            ORDER BY revisions.revision DESC LIMIT 1
        """).fetchone()
        if record is None:
            raise RuntimeError("The synthetic workspace has no stored revision.")
        version, digest, body, chunked = record
        if chunked not in (0, 1) or (chunked == 1 and body != "null"):
            raise RuntimeError("Invalid workspace document storage format.")
        raw = chunked_document(db, digest) if chunked == 1 else body.encode()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise RuntimeError("The workspace document digest does not match the stored revision.")
        workspace = json.loads(raw)
        state = {
            "revision": version,
            "digest": digest,
            "storage_format": "chunked" if chunked == 1 else "inline",
            "counts": {name: len(workspace[name]) for name in ("events", "tasks", "notes")},
            "quick_check": db.execute("PRAGMA quick_check(1)").fetchone()[0],
        }
        if include_document:
            state["document"] = workspace
        return state


def chunked_document(db, digest):
    output = bytearray()
    records = db.execute("""
        SELECT refs.ordinal, refs.chunk, parts.raw_bytes, parts.compressed
        FROM document_chunk_refs AS refs
        LEFT JOIN document_chunks AS parts ON parts.digest = refs.chunk
        WHERE refs.document = ?
        ORDER BY refs.ordinal
    """, (digest,))
    for index, (ordinal, chunk_digest, size, compressed) in enumerate(records):
        if ordinal != index or not isinstance(size, int) or not 1 <= size <= 65536:
            raise RuntimeError("Invalid workspace chunk metadata.")
        if not isinstance(compressed, bytes) or not 1 <= len(compressed) <= 65664:
            raise RuntimeError("Invalid compressed workspace chunk.")
        decoder = zlib.decompressobj()
        try:
            raw = decoder.decompress(compressed, size + 1)
        except zlib.error as error:
            raise RuntimeError("The workspace chunk cannot be decompressed.") from error
        if len(raw) != size or not decoder.eof or decoder.unused_data:
            raise RuntimeError("Invalid workspace chunk contents.")
        if hashlib.sha256(raw).hexdigest() != chunk_digest:
            raise RuntimeError("The workspace chunk digest does not match its reference.")
        if len(output) + size > 144 * 1024 * 1024:
            raise RuntimeError("The synthetic workspace exceeds the bounded document size.")
        output.extend(raw)
    if not output:
        raise RuntimeError("The chunked workspace has no data.")
    return output


def wait_for_workspace(path, timeout=15):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return workspace_state(path)
        except (sqlite3.OperationalError, RuntimeError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.2)


def run_cycle(args, window, scratch, index):
    def send(*arguments):
        send_input(args.xdotool, *arguments)

    def resize(width, height):
        send("windowsize", "--sync", window, width, height)
        time.sleep(0.20)

    def navigate(y):
        send("mousemove", "--window", window, 76, y, "click", 1)
        time.sleep(0.22)

    def scroll(x, y, direction):
        send("mousemove", "--window", window, x, y,
             "click", "--repeat", 6, "--delay", 65, direction)

    resize(*VIEWPORTS[-1])
    wait_for_resize(window, True, args.x11_capture)
    page_checks = {}
    for (name, y, heading) in PAGES:
        navigate(y)
        if index % args.check_every == 0:
            send("mousemove", "--window", window, 1256, 49)
            page_checks[name] = check_desktop_route(window, scratch, y, heading, args)
        if name != "Today":
            scroll(665, 530, 5)
            scroll(665, 530, 4)

    width, height = VIEWPORTS[index % len(VIEWPORTS)]
    resize(width, height)
    orbit_check = None
    if page_checks and width < 720:
        wait_for_resize(window, False, args.x11_capture)
        send(
            "mousemove", "--window", window, 48, height - 48, "mousedown", 1,
            "sleep", 0.48, "mousemove", "--window", window, 108, height - 151,
            "sleep", 0.18, "mouseup", 1,
        )
        orbit_check = check_visible_page(
            window, scratch,
            r"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b",
            args, crop=f"{width - 32}x115+16+4",
        )
    scroll(220, 410, 5)
    scroll(220, 410, 4)
    return page_checks, orbit_check


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=1800)
    parser.add_argument("--minimum-cycles", type=int, default=100)
    parser.add_argument("--check-every", type=int, default=10)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--workspace-database", type=Path,
        help="read-only integrity checks of the disposable synthetic workspace database",
    )
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--x11-capture", default="import")
    parser.add_argument("--tesseract", default="tesseract")
    args = parser.parse_args()
    if args.seconds < 1 or args.minimum_cycles < 1 or args.check_every < 1:
        parser.error("Duration and cycle counts must be positive.")

    window, pid = visible_window(args.xdotool)
    executable = Path(f"/proc/{pid}/exe").resolve(strict=True)
    app_library = executable.parent / "lib" / "libapp.so"
    workspace_before = (
        wait_for_workspace(args.workspace_database) if args.workspace_database else None
    )
    start = time.monotonic()
    evidence = {
        "run_at_utc": datetime.now(timezone.utc).isoformat(),
        "app_revision": args.app_revision,
        "executable_sha256": sha256(executable),
        "aot_library_sha256": sha256(app_library) if app_library.is_file() else None,
        "host": host_details(sorted(os.sched_getaffinity(0))),
        "viewports": VIEWPORTS,
        "target_seconds": args.seconds,
        "minimum_cycles": args.minimum_cycles,
        "affinity": sorted(os.sched_getaffinity(pid)),
        "cycles": 0,
        "observations": [],
        "start_memory_kib": process_rss(pid),
        "workspace_before": workspace_before,
        "status": "running",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="easy-ui-soak-") as directory:
            scratch = Path(directory)
            while evidence["cycles"] < args.minimum_cycles or time.monotonic() - start < args.seconds:
                index = evidence["cycles"]
                checks, orbit = run_cycle(args, window, scratch, index)
                memory = process_rss(pid)
                evidence["cycles"] += 1
                if checks:
                    elapsed = round(time.monotonic() - start, 2)
                    evidence["observations"].append({
                        "cycle": index + 1,
                        "elapsed_seconds": elapsed,
                        "memory_kib": memory,
                        "desktop_routes": checks,
                        "mobile_orbit_calendar": orbit,
                    })
                    pending = args.output.with_suffix(".partial.json")
                    staged = pending.with_suffix(".tmp")
                    staged.write_text(json.dumps(evidence, indent=2) + "\n")
                    staged.replace(pending)
        evidence["status"] = "complete"
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        evidence.update(status="interrupted", error=str(error))
    finally:
        evidence["elapsed_seconds"] = round(time.monotonic() - start, 2)
        evidence["host"]["cgroup_memory_events_after"] = host_text("/sys/fs/cgroup/memory.events")
        try:
            evidence["final_memory_kib"] = process_rss(pid)
        except OSError:
            evidence["final_memory_kib"] = None
        desktop_checks = [
            check
            for observation in evidence["observations"]
            for check in observation["desktop_routes"].values()
        ]
        evidence["desktop_route_checks"] = len(desktop_checks)
        evidence["desktop_route_mismatches"] = sum(not check["selected"] for check in desktop_checks)
        evidence["desktop_headings_visible"] = sum(check["heading_visible"] for check in desktop_checks)
        orbit_checks = [
            observation["mobile_orbit_calendar"]
            for observation in evidence["observations"]
            if observation["mobile_orbit_calendar"] is not None
        ]
        evidence["orbit_checks"] = len(orbit_checks)
        evidence["orbit_mismatches"] = sum(not check["matched"] for check in orbit_checks)
        if args.workspace_database:
            try:
                evidence["workspace_after"] = workspace_state(args.workspace_database)
                evidence["workspace_verified"] = (
                    workspace_before == evidence["workspace_after"]
                    and workspace_before["quick_check"] == "ok"
                )
            except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
                evidence.update(workspace_verified=False, workspace_check_error=str(error))
        args.output.write_text(json.dumps(evidence, indent=2) + "\n")
    if (evidence["status"] != "complete" or evidence["desktop_route_mismatches"]
            or evidence["orbit_mismatches"] or evidence.get("workspace_verified") is False):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
