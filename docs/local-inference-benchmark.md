# Local CPU inference benchmark

This harness measures actual llama.cpp requests on a set of 12 synthetic productivity captures. It checks kind, focus, title, and schedule with fixed expected outputs. The set covers explicit cross-focus routing, missing event details, workout logs, and cases that require clarification. This is a comparative smoke benchmark for this prompt and these checkpoints.

## Reproduce

The runner uses Python 3, Linux `taskset` and `prlimit`, and the pinned x86-64 llama.cpp server release. Download artifacts into a scratch directory and keep them outside the project. [llama.cpp b12657 release](https://github.com/ggml-org/llama.cpp/releases/tag/b12657) · [MIT license](https://github.com/ggml-org/llama.cpp/blob/b12657/LICENSE)

```sh
easy_bench_dir=$(mktemp -d)
cd "$easy_bench_dir"
curl -fL https://github.com/ggml-org/llama.cpp/releases/download/b12657/llama-b12657-bin-ubuntu-x64.tar.gz -o llama-b12657.tar.gz
printf '%s\n' 'ee4fd1751a406fd93c4e1110cbadd253777861f29261f3e17fc6b751343d3e26  llama-b12657.tar.gz' | sha256sum -c
tar -xzf llama-b12657.tar.gz
curl -fL https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf -o qwen2.5-0.5b-instruct-q4_k_m.gguf
curl -fL https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf -o qwen2.5-1.5b-instruct-q4_k_m.gguf
printf '%s\n' \
  '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db  qwen2.5-0.5b-instruct-q4_k_m.gguf' \
  '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e  qwen2.5-1.5b-instruct-q4_k_m.gguf' | sha256sum -c
```

Both model files come from the official Qwen repositories and use the Apache 2.0 license. The pinned 0.5B checkpoint is 491,400,032 bytes and the pinned 1.5B checkpoint is 1,117,320,736 bytes. [0.5B model card](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/9217f5db79a29953eb74d5343926648285ec7e67) · [1.5B model card](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/tree/91cad51170dc346986eccefdc2dd33a9da36ead9) · [Model license](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/9217f5db79a29953eb74d5343926648285ec7e67/LICENSE)

Run these commands from the project root in the shell with `easy_bench_dir` still set.

```sh
python3 tool/benchmark/local_inference.py \
  --server "$easy_bench_dir/llama-b12657/llama-server" \
  --model "$easy_bench_dir/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  --warm-rounds 3 --output "$easy_bench_dir/qwen05-results.json"

python3 tool/benchmark/local_inference.py \
  --server "$easy_bench_dir/llama-b12657/llama-server" \
  --model "$easy_bench_dir/qwen2.5-1.5b-instruct-q4_k_m.gguf" \
  --model-sha256 6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e \
  --profile available-cpu --profile one-cpu-2560mib --profile one-cpu-1gib \
  --warm-rounds 3 --output "$easy_bench_dir/qwen15-results.json"
```

The runner verifies the model SHA-256, starts a new authenticated server on loopback per profile, pins CPU affinity, and records any startup error. Each successful profile sends one first request and then 36 sequential warm requests across the 12 fixed cases. GPU offload, runtime warmup and prompt caching are disabled. All requests use a 512-token context, a 96-token response cap, temperature zero, and JSON Schema output.

Process startup time runs from launch to a healthy endpoint. The first request measures a fresh model process after loading, with filesystem caches left alone. Warm latency measures the complete nonstreaming response at the client. The p95 uses the nearest-rank statistic. Decode throughput comes from runtime timings, and peak RSS comes from the launched process's Linux `VmHWM`. The capped profiles use `RLIMIT_AS`, which limits process virtual address space including mappings and stacks. Physical RAM requirements need a separate device measurement.

## Measured results

24 November 2026 on a shared Debian 13 x86-64 virtual machine with AMD EPYC 9V74, five visible logical CPUs, a four-CPU cgroup quota, a 16 GiB memory cap and zero configured swap. All tested inference was CPU-only. CPU affinity and process address-space limits simulate constraints within this same machine. Separate GPU, phone, battery and thermal figures would require device runs.

| Q4_K_M model and profile | Startup | First request | Warm p50 | Warm p95 | Median decode | Peak RSS | Schema-valid | Strict matches |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.5B, four CPUs | 0.61 s | 1.12 s | 1.30 s | 2.38 s | 53.45 tokens/s | 604 MiB | 36/36 | 6/36 |
| 0.5B, one CPU under 1536 MiB | 0.53 s | 2.79 s | 2.87 s | 3.85 s | 26.26 tokens/s | 602 MiB | 36/36 | 6/36 |
| 1.5B, four CPUs | 2.54 s | 3.89 s | 2.86 s | 8.89 s | 26.46 tokens/s | 1785 MiB | 36/36 | 0/36 |
| 1.5B, one CPU under 2560 MiB | 1.96 s | 6.06 s | 6.00 s | 6.92 s | 18.00 tokens/s | 1784 MiB | 36/36 | 0/36 |

The four-CPU 1.5B run had a longer tail than the one-CPU run. It ran on a shared host without exclusive cgroup performance isolation. Both checkpoints reported zero cached prompt tokens.

| Startup failure profile | Observed failure |
| --- | --- |
| 0.5B, one CPU under 1 GiB | CPU repacking could not allocate a 28.05 MiB buffer. The authenticated run reproduced this in two separate launches. |
| 0.5B, one CPU under 384 MiB | A 44.89 MiB allocation failed and the server aborted. |
| 1.5B, one CPU under 1 GiB | Mapping the model failed with `Cannot allocate memory`. |

In each successful profile the smaller model chose 12 of 36 correct kinds and 30 correct focuses. The larger model chose 21 correct kinds and 30 correct focuses, with strict mismatches from missing or changed title and schedule fields. The 0.5B strict successes were two distinct cases repeated three times. Both models chose an actionable kind on each of the three clarification fixtures. The 1.5B model treated a request to cancel all meetings as an event, while the 0.5B model proposed an `erase everything` task when asked to ignore the format. These results fail a gate for automatic actions.

Raw evidence includes request outputs, per-field scores, process timing and memory, failure logs, model digests and runtime build. The initial run is kept separately and contains the first startup failures. [0.5B evidence](benchmark-results/local-inference-epyc-qwen05-20261124.json) · [1.5B evidence](benchmark-results/local-inference-epyc-qwen15-20261124.json) · [Initial 0.5B run](benchmark-results/local-inference-epyc-qwen05-initial-20261124.json)
