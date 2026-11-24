#!/usr/bin/env python3
"""Measure offline Whisper transcription on synthetic clean and noisy speech."""

import argparse
from array import array
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import random
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import wave

from local_inference import host_details, host_text, sha256


MODEL_DIGESTS = {
    "ggml-tiny.en.bin": "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
    "ggml-base.en.bin": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
}
VOICES = ("en-gb", "en-us")
RATE = 16000
NOISE_DB = 12
SEED = 20261124


def render_wave(case, voice, prefix, args):
    source = prefix.with_suffix(".raw.wav")
    clean = prefix.with_suffix(".clean.wav")
    noisy = prefix.with_suffix(".noisy.wav")
    tts = [str(args.espeak)]
    if args.espeak_data:
        tts.append(f"--path={args.espeak_data}")
    subprocess.run(
        [*tts, "-v", voice, "-s", "150", "-w", source, case["text"]], check=True
    )
    subprocess.run([
        args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", source,
        "-ar", str(RATE), "-ac", "1", "-c:a", "pcm_s16le", clean,
    ], check=True)

    with wave.open(str(clean), "rb") as audio:
        parameters = audio.getparams()
        samples = array("h", audio.readframes(parameters.nframes))
    if sys.byteorder != "little":
        samples.byteswap()
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
    noise = rms / 10 ** (NOISE_DB / 20)
    randomizer = random.Random(SEED + sum(map(ord, prefix.name)))
    mixed = array("h", (
        max(-32768, min(32767, round(sample + randomizer.gauss(0, noise))))
        for sample in samples
    ))
    if sys.byteorder != "little":
        mixed.byteswap()
    with wave.open(str(noisy), "wb") as audio:
        audio.setparams(parameters)
        audio.writeframes(mixed.tobytes())
    source.unlink()
    audio_ms = round(parameters.nframes * 1000 / RATE, 2)
    return [
        {
            "id": f"{case['id']}-{voice}-{condition}",
            "case": case,
            "voice": voice,
            "condition": condition,
            "audio_ms": audio_ms,
            "path": path,
            "audio_sha256": sha256(path),
        }
        for condition, path in (("clean", clean), ("noisy", noisy))
    ]


def words(text):
    return re.findall(r"[a-z]+|\d+", text.casefold())


def errors(source, transcript):
    previous = list(range(len(transcript) + 1))
    for row, expected in enumerate(source, 1):
        current = [row]
        for column, actual in enumerate(transcript, 1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (expected != actual),
            ))
        previous = current
    return previous[-1]


def grade(path, clip):
    response = json.loads(path.read_text())
    text = " ".join(
        segment["text"].strip()
        for segment in response["transcription"]
        if segment["text"].strip()
    )
    actual = words(text)
    reference = words(clip["case"]["text"])
    padded = f" {' '.join(actual)} "
    missing = [
        alternatives for alternatives in clip["case"]["required"]
        if not any(f" {' '.join(words(value))} " in padded for value in alternatives)
    ]
    return {
        "clip_id": clip["id"],
        "transcript": text,
        "language": response.get("result", {}).get("language"),
        "reference_words": len(reference),
        "word_errors": errors(reference, actual),
        "missing_facts": missing,
        "fact_pass": not missing,
    }


def invoke(args, model, clips, cpus, limit_mib, output):
    output.mkdir()
    peak_file = output / "rss.txt"
    command = [
        str(args.time), "-o", str(peak_file), "-f", "%M",
        "taskset", "-c", ",".join(map(str, cpus)),
    ]
    if limit_mib is not None:
        command.extend(["prlimit", f"--as={limit_mib * 1024 * 1024}", "--"])
    command.extend([
        str(args.whisper), "--model", str(model), "--language", "en",
        "--threads", str(len(cpus)), "--processors", "1", "--no-gpu", "--output-json",
    ])
    outputs = [output / clip["id"] for clip in clips]
    for clip, prefix in zip(clips, outputs):
        command.extend(["--file", str(clip["path"]), "--output-file", str(prefix)])

    started = time.monotonic()
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        start_new_session=True, text=True,
    ) as process:
        timed_out = False
        try:
            log = process.communicate(timeout=max(45, len(clips) * 15))[0]
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            log = process.communicate()[0]
    elapsed = (time.monotonic() - started) * 1000
    peaks = peak_file.read_text().splitlines() if peak_file.exists() else []
    peak = next((int(line) for line in reversed(peaks) if line.isdigit()), None)
    load = re.search(r"load time\s*=\s*([\d.]+)\s*ms", log)
    stats = {
        "wall_ms": round(elapsed, 2),
        "audio_ms": round(sum(clip["audio_ms"] for clip in clips), 2),
        "peak_rss_kib": peak,
        "model_load_ms": float(load[1]) if load else None,
        "exit_code": process.returncode,
        "timed_out": timed_out,
    }
    graded = []
    if process.returncode == 0:
        for prefix, clip in zip(outputs, clips):
            report = prefix.with_suffix(".json")
            if report.exists():
                graded.append(grade(report, clip))
    stats["real_time_factor"] = round(elapsed / stats["audio_ms"], 4)
    if len(graded) != len(clips):
        stats["failure_log_tail"] = log.splitlines()[-8:]
    return stats, graded


def summarise(cold, transcripts):
    accepted = [item for item in cold if item["transcription"] is not None]
    durations = sorted(item["wall_ms"] for item in accepted)
    rss = [item["peak_rss_kib"] for item in accepted if item["peak_rss_kib"] is not None]
    errors_total = sum(item["word_errors"] for item in transcripts)
    reference_total = sum(item["reference_words"] for item in transcripts)
    return {
        "cold_requests": len(cold),
        "cold_accepted": len(accepted),
        "cold_p50_ms": round(statistics.median(durations), 2) if durations else None,
        "cold_p95_ms": durations[math.ceil(len(durations) * .95) - 1] if durations else None,
        "peak_cold_rss_kib": max(rss) if rss else None,
        "warm_transcripts": len(transcripts),
        "warm_fact_pass": sum(item["fact_pass"] for item in transcripts),
        "warm_exact_transcripts": sum(item["word_errors"] == 0 for item in transcripts),
        "warm_word_error_rate": round(errors_total / reference_total, 4) if reference_total else None,
    }


def quality_by_condition(clips, transcripts):
    conditions = {clip["id"]: clip["condition"] for clip in clips}
    summary = {}
    for condition in sorted(set(conditions.values())):
        subset = [item for item in transcripts if conditions[item["clip_id"]] == condition]
        words = sum(item["reference_words"] for item in subset)
        errors = sum(item["word_errors"] for item in subset)
        summary[condition] = {
            "transcripts": len(subset),
            "fact_pass": sum(item["fact_pass"] for item in subset),
            "word_error_rate": round(errors / words, 4) if words else None,
        }
    return summary


def run_profile(args, model, clips, cpus, mib, target, cold_only=False):
    target.mkdir()
    results = {
        "model": model.name, "cpu_affinity": cpus, "address_space_mib": mib,
        "cold": [],
    }
    for index, clip in enumerate(clips[:1] if cold_only else clips):
        stats, graded = invoke(args, model, [clip], cpus, mib, target / f"cold-{index}")
        results["cold"].append({
            "clip_id": clip["id"], **stats,
            "transcription": graded[0] if graded else None,
        })
        if index == 0 and not graded:
            break
    transcripts = []
    if results["cold"][0]["transcription"] is not None and not cold_only:
        results["warm_batch"], transcripts = invoke(
            args, model, clips, cpus, mib, target / "batch"
        )
        results["warm_batch"]["transcriptions"] = transcripts
    results["summary"] = summarise(results["cold"], transcripts)
    results["quality_by_condition"] = quality_by_condition(clips, transcripts)
    print(
        model.name, cpus, mib, results["summary"]["cold_accepted"],
        results["summary"]["warm_transcripts"], flush=True,
    )
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--whisper", type=Path, required=True)
    parser.add_argument("--model", action="append", type=Path, required=True)
    parser.add_argument("--espeak", default="espeak-ng")
    parser.add_argument("--espeak-data", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--time", default="/usr/bin/time")
    parser.add_argument("--cases", type=Path, default=Path(__file__).with_name("speech_cases.json"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.whisper = args.whisper.resolve()
    models = [path.resolve() for path in args.model]
    provenance = []
    for model in models:
        digest = sha256(model)
        if digest != MODEL_DIGESTS.get(model.name):
            parser.error(f"unknown or mismatched model: {model.name}")
        provenance.append({
            "name": model.name, "sha256": digest, "size_bytes": model.stat().st_size,
        })
    cases = json.loads(args.cases.read_text())
    if not cases or len({case["id"] for case in cases}) != len(cases):
        parser.error("cases must be non-empty and have unique IDs")
    if any(not re.fullmatch(r"[a-z0-9_]+", case["id"]) for case in cases):
        parser.error("case IDs must contain lower-case letters, digits or underscores")
    cpus = sorted(os.sched_getaffinity(0))
    tts = subprocess.run([args.espeak, "--version"], capture_output=True, text=True, check=True)
    ffmpeg = subprocess.run([args.ffmpeg, "-version"], capture_output=True, text=True, check=True)
    with tempfile.TemporaryDirectory(prefix="easy-speech-") as directory:
        root = Path(directory)
        clips = [
            clip
            for case in cases
            for voice in VOICES
            for clip in render_wave(case, voice, root / f"{case['id']}-{voice}", args)
        ]
        evidence = {
            "run_at_utc": datetime.now(timezone.utc).isoformat(),
            "host": host_details(cpus),
            "whisper_sha256": sha256(args.whisper),
            "models": provenance,
            "cases_sha256": sha256(args.cases),
            "signal": {
                "rate_hz": RATE, "voices": VOICES, "noise_db": NOISE_DB, "seed": SEED,
                "espeak": tts.stdout.partition(" Data at:")[0].strip(),
                "ffmpeg": ffmpeg.stdout.splitlines()[0],
            },
            "clips": [{key: value for key, value in clip.items() if key != "path"} for clip in clips],
            "profiles": [],
        }
        for model in models:
            for selected, mib in ((cpus[:4], None), (cpus[:1], 1024)):
                label = f"{model.stem}-{len(selected)}-{mib}"
                evidence["profiles"].append(
                    run_profile(args, model, clips, selected, mib, root / label)
                )
        model = models[-1]
        evidence["profiles"].append(
            run_profile(args, model, clips, cpus[:1], 128, root / "memory-floor", cold_only=True)
        )
        evidence["host"]["cgroup_memory_events_after"] = host_text("/sys/fs/cgroup/memory.events")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
