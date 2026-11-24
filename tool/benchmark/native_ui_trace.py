#!/usr/bin/env python3
"""Replay a Linux Easy UI stress sequence and summarise real Flutter spans."""

import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import time
from urllib.parse import urlsplit

FRAME_NAMES = ("Frame", "Rasterizer::DoDraw")


class VmService:
    def __init__(self, connection):
        self.connection = connection
        self.request_id = 0

    def call(self, method):
        self.request_id += 1
        self.connection.send(json.dumps({
            "id": self.request_id, "jsonrpc": "2.0", "method": method, "params": {},
        }))
        while True:
            reply = json.loads(self.connection.recv(timeout=30))
            if reply.get("id") == self.request_id:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply["result"]


def local_vm_uri(machine_log):
    uri = None
    for line in machine_log.read_text().splitlines():
        try:
            entries = json.loads(line)
        except ValueError:
            continue
        for entry in entries if isinstance(entries, list) else [entries]:
            if isinstance(entry, dict) and entry.get("event") == "app.debugPort":
                uri = entry["params"]["wsUri"]
    target = urlsplit(uri or "")
    if target.scheme != "ws" or target.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise ValueError("Machine log must contain a running local VM Service.")
    return uri


def span_durations(events, name):
    spans = []
    open_events = {}
    unmatched = 0
    for event in sorted(events, key=lambda item: item.get("ts", 0)):
        if event.get("name") != name:
            continue
        phase = event.get("ph")
        key = (event.get("pid"), event.get("tid"), event.get("id"))
        if phase in ("b", "B"):
            open_events.setdefault(key, []).append(event["ts"])
        elif phase in ("e", "E"):
            stack = open_events.get(key, [])
            if stack:
                spans.append((event["ts"] - stack.pop()) / 1000)
            else:
                unmatched += 1
        elif phase == "X":
            spans.append(event["dur"] / 1000)
    return spans, unmatched + sum(map(len, open_events.values()))


def span_summary(samples, unmatched):
    if not samples:
        raise ValueError("No timing spans were recorded.")
    ordered = sorted(samples)
    return {
        "samples_ms": samples,
        "count": len(samples),
        "unmatched_events": unmatched,
        "median_ms": round(statistics.median(samples), 3),
        "p95_ms": ordered[math.ceil(len(samples) * 0.95) - 1],
        "max_ms": ordered[-1],
        "over_16_67_ms": sum(value > 16.67 for value in samples),
    }


def send_input(xdotool, *arguments):
    subprocess.run([xdotool, *map(str, arguments)], check=True, timeout=15)


def prepare_calendar(xdotool, window):
    send_input(xdotool, "windowsize", "--sync", window, 1280, 900)
    time.sleep(0.35)
    send_input(xdotool, "mousemove", "--window", window, 76, 148, "click", 1)
    time.sleep(0.45)
    send_input(xdotool, "windowsize", "--sync", window, 390, 844)
    time.sleep(0.55)


def drive(xdotool, window, calendar_only=False):
    def send(*arguments):
        send_input(xdotool, *arguments)

    def click(x, y):
        send("mousemove", "--window", window, x, y, "click", 1)
        time.sleep(0.2)

    def resize(width, height):
        send("windowsize", "--sync", window, width, height)
        time.sleep(0.13)

    def wheel(x, y, direction, count):
        send(
            "mousemove", "--window", window, x, y,
            "click", "--repeat", count, "--delay", 55, direction,
        )

    if calendar_only:
        for direction in (4, 5, 4, 5, 4, 5):
            wheel(225, 490, direction, 16)
        time.sleep(0.45)
        return

    resize(1280, 900)
    click(76, 101)
    click(76, 148)
    wheel(680, 520, 5, 12)
    wheel(680, 520, 4, 12)
    click(76, 195)
    wheel(680, 520, 5, 15)
    click(76, 242)
    wheel(680, 520, 5, 15)
    for _ in range(5):
        for width, height in ((390, 844), (320, 680), (760, 840), (1280, 900)):
            resize(width, height)
    resize(390, 844)
    send(
        "mousemove", "--window", window, 48, 796, "mousedown", 1,
        "sleep", 0.4, "mousemove", "--window", window, 115, 669,
        "sleep", 0.15, "mouseup", 1,
    )
    time.sleep(0.25)
    wheel(225, 490, 5, 16)
    wheel(225, 490, 4, 16)
    time.sleep(0.35)


def pin_process(pid, cpus):
    subprocess.run(
        ["taskset", "-apc", ",".join(map(str, cpus)), str(pid)],
        stdout=subprocess.DEVNULL, check=True, timeout=15,
    )


def process_rss(pid):
    values = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        field, _, value = line.partition(":")
        if field in ("VmHWM", "VmRSS"):
            values[field] = int(value.split()[0])
    return values


def main():
    from websockets.sync.client import connect

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--machine-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument(
        "--calendar-only", action="store_true",
        help="replay steady mobile Calendar wheel motion without viewport changes",
    )
    args = parser.parse_args()
    matches = subprocess.check_output(
        [args.xdotool, "search", "--onlyvisible", "--name", "^Easy$"], text=True
    ).splitlines()
    if len(matches) != 1:
        parser.error("Run this in a display with exactly one visible Easy window.")
    window = matches[0]
    pid = int(subprocess.check_output([args.xdotool, "getwindowpid", window], text=True))
    original_affinity = sorted(os.sched_getaffinity(pid))
    available_cpus = sorted(os.sched_getaffinity(0))
    uri = local_vm_uri(args.machine_log)
    profiles = []
    try:
        with connect(uri, max_size=None, open_timeout=8) as connection:
            vm = VmService(connection)
            streams = vm.call("getVMTimelineFlags")["recordedStreams"]
            for cpus in (available_cpus[:4], available_cpus[:1]):
                pin_process(pid, cpus)
                if args.calendar_only:
                    prepare_calendar(args.xdotool, window)
                vm.call("clearVMTimeline")
                drive(args.xdotool, window, args.calendar_only)
                events = vm.call("getVMTimeline")["traceEvents"]
                profiles.append({
                    "cpu_affinity": cpus,
                    "process_memory_kib": process_rss(pid),
                    "event_count": len(events),
                    "timeline": {
                        name: span_summary(*span_durations(events, name))
                        for name in FRAME_NAMES
                    },
                })
    finally:
        pin_process(pid, original_affinity)
    evidence = {
        "workload": "mobile_calendar" if args.calendar_only else "mixed_workspace",
        "recorded_streams": streams,
        "profiles": profiles,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
