#!/usr/bin/env python3
"""Run the production duration provider against an isolated CPU-only llama.cpp server."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from local_inference import host_details, host_text, loopback_port, memory_details, sha256, wait_until_ready
from native_workspace_scale import stop


def run(args):
    allowed = sorted(os.sched_getaffinity(0))
    cpus = args.cpu or allowed[:1]
    if len(set(cpus)) != len(cpus) or not set(cpus).issubset(allowed):
        raise ValueError(f"CPUs must be distinct members of {allowed}.")
    if args.address_space_mib is not None and args.address_space_mib < 1:
        raise ValueError("An address-space limit must be positive.")
    if not re.fullmatch(r"[a-f0-9]{40}", args.source_revision):
        raise ValueError("Provide the full source revision used to compile the client.")
    model_digest = sha256(args.model)
    if model_digest != args.model_sha256:
        raise ValueError("Model SHA-256 did not match the expected artifact.")

    port = loopback_port()
    threads = str(len(cpus))
    alias = "duration-benchmark"
    launch = ["taskset", "-c", ",".join(map(str, cpus))]
    if args.address_space_mib is not None:
        launch += ["prlimit", f"--as={args.address_space_mib * 1024**2}", "--"]
    launch += [
        str(args.server), "--model", str(args.model), "--alias", alias,
        "--host", "127.0.0.1", "--port", str(port), "--threads", threads,
        "--threads-batch", threads, "--ctx-size", "2048", "--parallel", "1",
        "--batch-size", "256", "--ubatch-size", "128", "--n-gpu-layers", "0",
        "--no-warmup", "--no-cache-prompt", "--cache-ram", "0", "--no-webui",
        "--no-webui-mcp-proxy", "--temp", "0", "--seed", "42",
    ]
    if args.disable_thinking:
        launch += ["--chat-template-kwargs", '{"enable_thinking":false}']
    host = host_details(allowed)
    evidence = {
        "cpu_affinity": cpus,
        "host": host,
        "address_space_limit_mib": args.address_space_mib,
        "runtime_sha256": sha256(args.server),
        "model_sha256": model_digest,
        "client_sha256": sha256(args.client),
        "cases_sha256": sha256(args.cases),
        "context_tokens": 2048,
        "thinking_disabled": args.disable_thinking,
    }
    with tempfile.TemporaryFile(mode="w+t") as log:
        started = time.monotonic()
        runtime = subprocess.Popen(launch, stdout=log, stderr=subprocess.STDOUT)
        try:
            failed = wait_until_ready(runtime, port, "", started + 75)
            evidence["runtime_start_ms"] = round((time.monotonic() - started) * 1000, 2)
            if failed:
                log.seek(0)
                tail = "\n".join(log.read().splitlines()[-10:])
                raise RuntimeError(f"{failed}\n{tail}")
            command = [
                str(args.client), f"http://127.0.0.1:{port}/v1", alias,
                str(args.cases), str(args.output), args.source_revision,
            ]
            for enabled, flag in (
                (args.json_object, "--json-object"),
                (args.experimental_schema, "--experimental-schema"),
                (args.experimental_history_guide, "--experimental-history-guide"),
            ):
                if enabled:
                    command.append(flag)
            subprocess.run(command, check=True, timeout=900)
            evidence["runtime_memory_kib"] = memory_details(runtime.pid)
            evidence["cgroup_memory_events_after"] = host_text("/sys/fs/cgroup/memory.events")
        finally:
            stop(runtime)
    report = json.loads(args.output.read_text())
    report.update(evidence)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-sha256", required=True)
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--cases", type=Path, default=Path(__file__).with_name("provider_estimate_cases.json"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu", type=int, action="append")
    parser.add_argument("--address-space-mib", type=int)
    parser.add_argument("--disable-thinking", action="store_true")
    wire = parser.add_mutually_exclusive_group()
    wire.add_argument("--json-object", action="store_true")
    wire.add_argument("--experimental-schema", action="store_true")
    parser.add_argument("--experimental-history-guide", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
