#!/usr/bin/env python3
"""Replay a synthetic voice capture with an isolated Linux virtual audio device."""

import argparse
from array import array
from collections import defaultdict
from contextlib import ExitStack
import csv
from datetime import date, datetime, timezone
import io
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import wave

from local_inference import host_details, sha256
from local_speech import render_wave, words
from native_ui_fixture import workspace
from native_ui_soak import visible_window, wait_for_workspace, workspace_state
from native_workspace_scale import stop


WIDTH, HEIGHT = 390, 844
VIRTUAL_SINK = "easy_benchmark_virtual"
VIRTUAL_MONITOR = f"{VIRTUAL_SINK}.monitor"
VIRTUAL_SOURCE = "easy_benchmark_input"
SHOPPING_WORDS = ("weekend", "shopping", "list")


def until(check, description, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        result = check()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out waiting for {description}.")
        time.sleep(0.2)


def command(env, *args, timeout=15):
    result = subprocess.run(
        list(map(str, args)), env=env, check=True,
        capture_output=True, text=True, timeout=timeout,
    )
    return result.stdout


def start_child(stack, env, log, *args, pipe=False):
    output = stack.enter_context(log.open("wb"))
    child = subprocess.Popen(
        args, env=env, stdout=subprocess.PIPE if pipe else output, stderr=output,
    )
    stack.callback(stop, child)
    return child


def set_up_audio(args, stage, env, stack):
    socket = stage / "pulse.sock"
    setup = stage / "pulse.pa"
    setup.write_text(
        f".fail\nload-module module-native-protocol-unix socket={socket} auth-anonymous=1\n"
        f"load-module module-null-sink sink_name={VIRTUAL_SINK} rate=16000 channels=1 "
        f"format=s16le channel_map=mono\n"
        f"load-module module-remap-source master={VIRTUAL_MONITOR} source_name={VIRTUAL_SOURCE}\n"
        f"set-default-sink {VIRTUAL_SINK}\n"
        f"set-default-source {VIRTUAL_SOURCE}\n"
    )
    client = stage / "pulse-client.conf"
    client.write_text("autospawn = no\n")
    env.update(PULSE_SERVER=f"unix:{socket}", PULSE_SOURCE=VIRTUAL_SOURCE,
               PULSE_SINK=VIRTUAL_SINK, PULSE_CLIENTCONFIG=str(client))
    flags = [f"--dl-search-path={args.pulse_modules}"] if args.pulse_modules else []
    start_child(
        stack, env, stage / "audio.log", args.pulseaudio,
        "--daemonize=no", "--log-target=stderr", "--system=no", "--high-priority=no",
        "--realtime=no", "--use-pid-file=no", "--exit-idle-time=-1", "--disallow-exit",
        "--disallow-module-loading", *flags, "-n", "-F", setup,
    )
    until(socket.is_socket, "the private virtual audio server", seconds=6)

    def listed(kind):
        return [line.split("\t") for line in command(env, args.pactl, "list", "short", kind).splitlines()]

    sources, sinks, modules = (listed(kind) for kind in ("sources", "sinks", "modules"))
    if ({row[1] for row in sources} != {VIRTUAL_MONITOR, VIRTUAL_SOURCE} or
            [row[1] for row in sinks] != [VIRTUAL_SINK] or
            {row[1] for row in modules} != {
                "module-null-sink", "module-native-protocol-unix", "module-remap-source",
            }):
        raise RuntimeError("The virtual server exposes unexpected audio devices or modules.")
    source_ids = {row[1]: row[0] for row in sources}
    return source_ids, [row[1] for row in modules]


class Screen:
    def __init__(self, args, stage, env, window):
        self.args, self.env, self.window = args, env, window
        self.path = stage / "screen.png"

    def send(self, *args):
        command(self.env, self.args.xdotool, *args)

    def move(self, x, y):
        self.send("mousemove", "--window", self.window, x, y)

    def labels(self, layout=11, *, capture=True):
        if capture:
            command(self.env, self.args.x11_capture, "-window", self.window, self.path)
        rows = command(self.env, self.args.tesseract, self.path, "stdout", "--psm", layout, "tsv")
        lines = defaultdict(list)
        for row in csv.DictReader(io.StringIO(rows), delimiter="\t"):
            if row["text"] and row["level"] == "5":
                key = tuple(row[name] for name in ("block_num", "par_num", "line_num"))
                lines[key].append(row)
        return lines.values()

    def find(self, text):
        expected = words(text)
        for layout in (11, 6):
            for line in self.labels(layout, capture=layout == 11):
                tokens = [(token, row) for row in line for token in words(row["text"])]
                for start in range(len(tokens) - len(expected) + 1):
                    end = start + len(expected)
                    if [token for token, _ in tokens[start:end]] == expected:
                        first, last = tokens[start][1], tokens[end - 1][1]
                        return (
                            (int(first["left"]) + int(last["left"]) + int(last["width"])) // 2,
                            int(first["top"]) + int(first["height"]) // 2,
                        )
        return None

    def tap(self, text):
        self.move(*until(lambda: self.find(text), f"the {text!r} label"))
        self.send("click", 1)

    def tap_footer(self):
        self.move(WIDTH - 66, HEIGHT - 37)
        self.send("click", 1)


def audio_evidence(path):
    with wave.open(str(path), "rb") as clip:
        params = clip.getparams()
        if (params.nchannels, params.sampwidth, params.framerate) != (1, 2, 16000):
            raise RuntimeError("The attachment is not mono 16 kHz PCM16.")
        samples = array("h", clip.readframes(params.nframes))
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples or not any(samples):
        raise RuntimeError("The recorded fixture contains only silence.")
    return {
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
        "samples": len(samples),
        "duration_ms": round(len(samples) / 16, 2),
        "rms": round(math.sqrt(sum(sample * sample for sample in samples) / len(samples)), 2),
    }


def run(args, stage):
    env = {**os.environ, "GDK_BACKEND": "x11", "LIBGL_ALWAYS_SOFTWARE": "1",
           "GSETTINGS_BACKEND": "memory", "OMP_THREAD_LIMIT": "1"}
    for name in ("DATA", "CONFIG", "CACHE", "RUNTIME"):
        location = stage / name.lower()
        location.mkdir(mode=0o700)
        env[f"XDG_{name}_HOME" if name != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(location)
    data = Path(env["XDG_DATA_HOME"]) / "app.launchsites.easy"
    data.mkdir()
    initial = workspace(date.today(), 0, 0, 0)
    (data / "shared_preferences.json").write_text(json.dumps({
        "easy.workspace.v1": json.dumps(initial, separators=(",", ":")),
        "easy.voice-transcription.v1": json.dumps({
            "executable": str(args.whisper), "model": str(args.model),
        }),
    }))
    database = data / "easy" / "workspace.sqlite3"
    cases = json.loads(Path(__file__).with_name("speech_cases.json").read_text())
    case, = (case for case in cases if case["id"] == "personal_note")
    clean, _ = render_wave(case, "en-gb", stage / case["id"], args)
    started = time.monotonic()

    with ExitStack() as system:
        source_ids, modules = set_up_audio(args, stage, env, system)
        source = source_ids[VIRTUAL_SOURCE]
        monitor = source_ids[VIRTUAL_MONITOR]
        display = start_child(system, env, stage / "display.log", args.xvfb, "-displayfd", "1",
                              "-screen", "0", "1440x1000x24", "-nolisten", "tcp", "-ac", "-noreset", pipe=True)
        with selectors.DefaultSelector() as selector:
            selector.register(display.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=8):
                raise RuntimeError("The isolated display did not start.")
            env["DISPLAY"] = f":{int(display.stdout.readline())}"

        def open_app(stack, name):
            launch = ["taskset", "-c", str(args.cpu)] if args.cpu is not None else []
            if args.block_ip:
                launch.append(args.block_ip)
            start_child(stack, env, stage / f"{name}.log", *launch, args.binary)

            def locate():
                try:
                    return visible_window(args.xdotool, env=env)[0]
                except subprocess.CalledProcessError:
                    return None

            window = until(locate, "the Easy window", seconds=45)
            screen = Screen(args, stage, env, window)
            screen.send("windowfocus", window)
            screen.send("windowsize", "--sync", window, WIDTH, HEIGHT)
            return screen

        def sources_for_recording():
            listing = command(env, args.pactl, "list", "short", "source-outputs").splitlines()
            # The remap module connects to its monitor while the app records.
            # That upstream link is part of the fixture, not a second recorder.
            outputs = [row.split("\t") for row in listing]
            return [row[1] for row in outputs if row[1] != monitor]

        with ExitStack() as active:
            screen = open_app(active, "capture")
            before = wait_for_workspace(database)
            screen.tap("Mode")
            screen.tap("Gym")

            def gym_heading():
                location = screen.find("Gym")
                return location is not None and location[1] < 70

            until(gym_heading, "the active Gym focus")
            time.sleep(0.5)

            def take(cancel):
                def wait_for_recording():
                    observed = set()

                    def exact_source():
                        active = tuple(sources_for_recording())
                        observed.add(active)
                        return active == (source,)

                    try:
                        until(exact_source, "recording from the virtual source", seconds=8)
                    except RuntimeError as error:
                        screen.labels()
                        raise RuntimeError(f"{error} Observed source IDs {sorted(observed)}.") from error

                if args.interaction == "button":
                    screen.move(WIDTH - 48, HEIGHT - 48)
                    screen.send("click", 1)
                    until(lambda: screen.find("Task"), "the quick capture sheet")
                    screen.move(WIDTH - 137, HEIGHT - 115)
                    until(lambda: screen.find("Record voice"), "the voice button tooltip")
                    screen.send("click", 1)
                    until(lambda: screen.find("Voice capture"), "the voice capture sheet")
                    wait_for_recording()
                    command(env, args.paplay, "--latency-msec=25", "--device", VIRTUAL_SINK, clean["path"])
                    time.sleep(0.35)
                    screen.tap("Cancel" if cancel else "Stop and save")
                elif args.interaction == "lock" and not cancel:
                    screen.send("mousemove", "--window", screen.window, WIDTH - 48, HEIGHT - 48,
                                "mousedown", 1, "sleep", 1.4, "mousemove", "--window", screen.window,
                                WIDTH - 48, HEIGHT - 140, "sleep", 0.25, "mouseup", 1)
                    wait_for_recording()
                    screen.move(WIDTH // 2, HEIGHT // 2)
                    screen.send("click", 1)
                    until(lambda: screen.find("Stop and save"), "the locked capture controls")
                    wait_for_recording()
                    command(env, args.paplay, "--latency-msec=25", "--device", VIRTUAL_SINK, clean["path"])
                    time.sleep(0.35)
                    screen.tap("Stop and save")
                else:
                    screen.move(WIDTH - 48, HEIGHT - 48)
                    screen.send("mousedown", 1)
                    try:
                        until(lambda: screen.find("Voice capture"), "the voice capture sheet", seconds=5)
                        wait_for_recording()
                        command(env, args.paplay, "--latency-msec=25", "--device", VIRTUAL_SINK, clean["path"])
                        time.sleep(0.4)
                        if cancel:
                            screen.move(WIDTH - 130, HEIGHT - 48)
                            until(lambda: screen.find("Release to cancel"), "the slide-to-cancel cue", seconds=5)
                    finally:
                        screen.send("mouseup", 1)
                until(lambda: not sources_for_recording(), "the recorder stopping")

            take(cancel=True)
            until(gym_heading, "the Gym page after cancel")
            after_cancel = workspace_state(database)
            if before != after_cancel or list(data.glob("easy/attachments/*/payload")):
                raise RuntimeError("Cancelling voice capture changed the workspace or stored audio.")

            take(cancel=False)
            until(lambda: screen.find("Capture review"), "the editable capture review")
            saved = workspace_state(database, include_document=True)
            draft, = saved["document"].get("captures", [])
            if draft["applied"] or draft["text"]:
                raise RuntimeError("The recording must be saved before interpreting it.")
            ref = draft["audio"]
            if not re.fullmatch(r"[a-f0-9]{64}", ref["id"]):
                raise RuntimeError("Invalid attachment reference.")
            path = data / "easy" / "attachments" / ref["id"] / "payload"
            captured = audio_evidence(path)
            if (captured["sha256"], captured["bytes"]) != (ref["id"], ref["byteLength"]):
                raise RuntimeError("The attachment does not match its stored reference.")

            screen.tap("Transcribe locally")
            transcribing = time.monotonic()

            def has_transcript():
                state = workspace_state(database, include_document=True)
                entry, = state["document"]["captures"]
                return entry["text"] or None

            transcript = until(has_transcript, "the local transcript", seconds=35)
            latency = round((time.monotonic() - transcribing) * 1000, 2)
            if not all(term in words(transcript) for term in SHOPPING_WORDS):
                raise RuntimeError("Local transcription missed the synthetic shopping list.")
            time.sleep(0.5)
            screen.tap_footer()
            until(lambda: screen.find("Note Personal"), "the editable Personal note proposal")
            reviewed = workspace_state(database, include_document=True)
            if ([note["id"] for note in reviewed["document"]["notes"]] !=
                    [note["id"] for note in initial["notes"]] or
                    reviewed["document"]["captures"][0]["applied"]):
                raise RuntimeError("A draft was added before confirmation.")
            screen.tap_footer()
            until(gym_heading, "the Gym page after saving the Personal note")

            def confirmed_note():
                state = workspace_state(database, include_document=True)
                return state if state["counts"]["notes"] == len(initial["notes"]) + 1 else None

            final = until(confirmed_note, "the reviewed note to persist")
            note, = [note for note in final["document"]["notes"] if note["id"] != initial["notes"][0]["id"]]
            stored, = final["document"]["captures"]
            if note["category"] != "personal" or not stored["applied"] or stored["audio"] != ref:
                raise RuntimeError("The reviewed note or its audio did not persist correctly.")
            if not all(term in words(note["title"]) for term in SHOPPING_WORDS):
                raise RuntimeError("The confirmed note does not match the synthetic clip.")

        with ExitStack() as restarted:
            screen = open_app(restarted, "restart")
            until(lambda: screen.find("Mode"), "the home page after restart")
            reopened = workspace_state(database, include_document=True)
            if reopened != final or audio_evidence(path) != captured:
                raise RuntimeError("The workspace or audio changed after restarting.")

    return {
        "status": "passed", "run_at_utc": datetime.now(timezone.utc).isoformat(),
        "app_revision": args.app_revision, "executable_sha256": sha256(args.binary),
        "aot_library_sha256": sha256(args.binary.parent / "lib" / "libapp.so"),
        "host": host_details(sorted(os.sched_getaffinity(0))), "app_cpu": args.cpu,
        "viewport": [WIDTH, HEIGHT], "audio_modules": modules, "only_virtual_audio": True,
        "capture_interaction": args.interaction,
        "app_ip_socket_guard": args.block_ip is not None, "recorded_wav": captured,
        "synthetic_wav_sha256": clean["audio_sha256"], "whisper_sha256": sha256(args.whisper),
        "model_sha256": sha256(args.model), "transcript": transcript, "transcription_ms": latency,
        "cancel_preserved_workspace": True, "saved_before_transcription": True,
        "review_required": True, "active_focus_after_confirmation": "gym", "note_category": "personal",
        "workspace_revisions": [before["revision"], after_cancel["revision"], saved["revision"], final["revision"]],
        "workspace_digest_after_restart": reopened["digest"], "workspace_quick_check": reopened["quick_check"],
        "seconds": round(time.monotonic() - started, 2),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--whisper", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--interaction", choices=("hold", "lock", "button"), default="hold")
    parser.add_argument("--espeak", default="espeak-ng")
    parser.add_argument("--espeak-data", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--pulseaudio", default="pulseaudio")
    parser.add_argument("--pulse-modules", type=Path)
    parser.add_argument("--pactl", default="pactl")
    parser.add_argument("--paplay", default="paplay")
    parser.add_argument("--xvfb", default="Xvfb")
    parser.add_argument("--xdotool", default="xdotool")
    parser.add_argument("--x11-capture", default="import")
    parser.add_argument("--tesseract", default="tesseract")
    parser.add_argument("--block-ip", type=Path)
    parser.add_argument("--failure-image", type=Path, help="preserve the synthetic failure screenshot for diagnosis")
    parser.add_argument("--failure-logs", type=Path, help="save process logs after a failed synthetic run")
    args = parser.parse_args()
    for field in ("binary", "whisper", "model"):
        setattr(args, field, getattr(args, field).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="easy-voice-benchmark-") as target:
        stage = Path(target)
        try:
            report = run(args, stage)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            print(f"Voice smoke failed: {error}", file=sys.stderr)
            if args.failure_image and (stage / "screen.png").exists():
                args.failure_image.write_bytes((stage / "screen.png").read_bytes())
            if args.failure_logs:
                args.failure_logs.mkdir(parents=True, exist_ok=True)
                for log in stage.glob("*.log"):
                    shutil.copyfile(log, args.failure_logs / log.name)
            return 1
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
