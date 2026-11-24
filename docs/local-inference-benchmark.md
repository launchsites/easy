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

## Capture validation stress test

The application accepted 10,000 exact two-item model responses and withheld all 10,000 mutated batches. Seed `261124` varied the capture revision, workspace revision, category, focus, and Unicode text. Thirteen mutation classes covered altered UTF-16 spans, missing proposals, invented dates, wrong types, stale revisions, and values outside the checked interpretation. The one-CPU run took 6.45 seconds. A matching batch remains a proposal until the user confirms it. [Raw validation results](benchmark-results/capture-validation-fuzz-20261124.json)

```sh
TZ=Europe/London dart run tool/benchmark/capture_validation_fuzz.dart /tmp/easy-capture-validation.json
```

## AI budget accounting replay

A Dart AOT simulator compared the GBP ledger with independent integer accounting through 64 seeded request histories. Across 131,072 operations and 163,328 monthly report checks, every balance, charge and decision agreed. The cases included 5,235 serialization and restart cycles, 2,116 month changes and 14,481 settlements after the clock moved to a different month. The replay also covered changed caps, paid and unpaid local requests, missing usage, known non-dispatch, provider usage above the reserved limit and duplicate request IDs.

The one-CPU replay completed in 25.95 seconds. It exercised the local ledger without API calls. [Budget replay counts](benchmark-results/ai-budget-ledger-replay-20261124.json)

```sh
dart compile exe tool/benchmark/ai_budget_replay.dart -o /tmp/easy-ai-budget-replay
taskset -c 2 /tmp/easy-ai-budget-replay /tmp/easy-ai-budget-replay.json
```

## Qwen3-4B text sweep

The tested file was Qwen's Apache 2.0 Qwen3-4B Q4_K_M GGUF at revision `bc640142c66e1fdd12af0bd68f40445458f3869b`. The 2,497,280,256-byte file has SHA-256 `7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5`. This sweep reused the same 12 cases and schema with the model's thinking template disabled. [Qwen3-4B GGUF model card](https://huggingface.co/Qwen/Qwen3-4B-GGUF/tree/bc640142c66e1fdd12af0bd68f40445458f3869b)

| CPU and address-space profile | Startup | First request | Warm p50 | Warm p95 | Median decode | Peak RSS | Schema-valid | Strict matches |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Four CPUs, host limit | 6.72 s | 6.16 s | 7.38 s | 22.84 s | 10.70 tokens/s | 4.14 GiB | 26/36 | 5/36 |
| One CPU under 6 GiB | 7.86 s | 17.93 s | 16.51 s | 23.30 s | 6.40 tokens/s | 4.13 GiB | 36/36 | 9/36 |
| One CPU under 2 GiB | 0.51 s to mapping failure | — | — | — | — | — | — | — |

Ten four-CPU requests reached the 30-second client timeout. The p50 and p95 columns include successful responses. The shared cgroup recorded memory-limit reclaim events during the sweep and its OOM-kill count stayed at zero. The one-CPU profile produced three distinct strict matches. It proposed a task for all three multi-action clarification inputs and a workout log for all three literal-input clarification examples. These outcomes keep the reviewed capture gate necessary. [Raw 4B sweep](benchmark-results/local-inference-epyc-qwen4b-20261124.json)

```sh
curl -fL https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf -o "$easy_bench_dir/Qwen3-4B-Q4_K_M.gguf"
python3 tool/benchmark/local_inference.py \
  --server "$easy_bench_dir/llama-b12657/llama-server" \
  --model "$easy_bench_dir/Qwen3-4B-Q4_K_M.gguf" \
  --model-sha256 7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5 \
  --disable-thinking --profile one-cpu-2048mib --profile available-cpu \
  --profile one-cpu-6144mib --output "$easy_bench_dir/qwen4b-results.json"
```

The one-CPU, 6 GiB profile also ran continuously for 1,818 seconds after one warm pass. All 98 requests completed within the 30-second timeout, all returned schema-valid responses and 24 matched all intended fields. Latency p50 was 17.46 seconds and p95 was 27.76 seconds. Median decode speed was 5.69 tokens per second. The 25 memory samples showed 4.04–4.07 GiB resident and a 4.13 GiB peak. The runtime remained alive at completion, with zero cgroup OOM kills. This establishes sustained operation under that specific resource ceiling and the limits of the isolated model's interpretation accuracy. [Raw Qwen3-4B soak](benchmark-results/local-inference-epyc-qwen4b-soak-20261124.json)

Repeat with the same runtime and model by selecting the single-CPU profile and adding a 30-minute measurement window.

```sh
taskset -c 1 python3 tool/benchmark/local_inference.py \
  --server "$easy_bench_dir/llama-b12657/llama-server" \
  --model "$easy_bench_dir/Qwen3-4B-Q4_K_M.gguf" \
  --model-sha256 7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5 \
  --disable-thinking --profile one-cpu-6144mib --warm-rounds 1 \
  --soak-seconds 1800 --soak-progress "$easy_bench_dir/qwen4b-soak-progress.jsonl" \
  --output "$easy_bench_dir/qwen4b-soak-results.json"
```

## Offline speech pilot

The tested whisper.cpp b5907 Linux x86-64 CPU archive has SHA-256 `a6199027fe5b4239c84171d2bca4c0ff44ec86a515494d5a39b237b212d429bd`. The MIT model repository at revision `5359861c739e955e79d9a303bcbc70fb988958b1` supplied English `ggml-tiny.en.bin` at SHA-256 `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f` and `ggml-base.en.bin` at SHA-256 `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`. [whisper.cpp b5907 release](https://github.com/ggml-org/whisper.cpp/releases/tag/b5907) · [Model files](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1) · [OpenAI Whisper license](https://github.com/openai/whisper/blob/main/LICENSE)

Eight synthetic capture phrases used eSpeak NG 1.52.0 British and American English, then 16 kHz mono PCM conversion with FFmpeg. Each clean clip was paired with a seeded Gaussian-noise version at 12 dB target SNR. Each profile reused the same 32 clips, totaling 126.27 seconds. Cold trials launched a process per clip. Each batch reused one model process for all clips and includes its initial load in elapsed time. [Speech cases](../tool/benchmark/speech_cases.json)

| English model and profile | Cold p50 | Cold p95 | Batch wall time | Batch real-time factor | Batch peak RSS | All tested facts kept | Word error rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Tiny, four CPUs | 1.12 s | 3.97 s | 31.84 s | 0.252 | 175 MiB | 9/32 | 63.7% |
| Tiny, one CPU under 1 GiB | 1.50 s | 2.17 s | 56.47 s | 0.447 | 172 MiB | 9/32 | 63.7% |
| Base, four CPUs | 1.49 s | 5.85 s | 87.38 s | 0.692 | 283 MiB | 11/32 | 52.0% |
| Base, one CPU under 1 GiB | 3.34 s | 4.52 s | 101.39 s | 0.803 | 281 MiB | 11/32 | 52.0% |

Both CPU profiles produced the same scored transcripts for each model. The Tiny model kept all tested facts on six clean clips and three noisy clips. Base kept them on nine clean clips and two noisy clips. The Base memory-floor probe under 128 MiB exited during initialization and generated zero transcripts. [Raw speech sweep](benchmark-results/local-speech-epyc-20261124.json)

Fact checks use declared text alternatives for the names, times, quantities and labels. This lexical method also flags merged labels such as “Gymlog” on a clip that preserved the treadmill distance, incline and time. An example with a changed critical value is Tiny's clean coffee clip, which returned “10-11M” for the specified 10 to 11 A.M. range. These synthetic fixtures measure comparative behavior. Real microphones and human speech remain separate verification work.

With Python 3, eSpeak NG, FFmpeg and GNU time installed, run this command from the repository root using the verified runtime and model paths.

```sh
python3 tool/benchmark/local_speech.py \
  --whisper "$easy_bench_dir/whisper-bin-ubuntu-x64/whisper-cli" \
  --model "$easy_bench_dir/ggml-tiny.en.bin" \
  --model "$easy_bench_dir/ggml-base.en.bin" \
  --output "$easy_bench_dir/speech-results.json"
```

## Application provider V2 metadata pilot

The standalone Dart harness exercises the real loopback provider and validator at `db1a78f`. The frozen 19-case fixture checks cross-focus categories, explicit titles, a literal note, two-item capture, missing event details and unresolved or destructive inputs. Eight cases had no eligible model clause and made zero provider calls. The device parser handled the running, biology homework and shop social-plan examples in those controls. The remaining cases offered 11 model requests per profile. [V2 fixture](../tool/benchmark/provider_metadata_cases.json)

| Model on one CPU | Response mode | Responses accepted by the app | Median request time |
| --- | --- | ---: | ---: |
| Qwen2.5 0.5B | Plain | 0/11 | 8.37 s |
| Qwen2.5 0.5B | JSON object | 0/11 | 12.65 s |
| Qwen2.5 1.5B | Plain | 0/11 | 10.00 s |
| Qwen2.5 1.5B | JSON object | 0/11 | 10.09 s |

In the one-case diagnostic, the 0.5B model emitted Markdown fences in plain mode and a parseable object in JSON-object mode. Both objects echoed the supplied category table and clause list. Both omitted the required suggestions array and used the display label `Work` where the wire contract required a permitted ID. The application withheld every invalid result. [0.5B plain](benchmark-results/provider-metadata-v2-qwen05-plain-20261124.json) · [0.5B JSON object](benchmark-results/provider-metadata-v2-qwen05-json-20261124.json) · [1.5B plain](benchmark-results/provider-metadata-v2-qwen15-plain-20261124.json) · [1.5B JSON object](benchmark-results/provider-metadata-v2-qwen15-json-20261124.json) · [Diagnostic response](benchmark-results/provider-metadata-v2-qwen05-wire-20261124.json)

The test harness also supplied llama.cpp with an experimental response schema generated from the available clause numbers, kinds, category IDs and request revision. Each candidate still went through the production validator. The category-meanings variant replaced the prompt with short category descriptions while using the same grammar and fixture.

| Model on one CPU | Experimental mode | Accepted by validator | Exact intended items | Median request time |
| --- | --- | ---: | ---: | ---: |
| Qwen2.5 0.5B | Schema | 11/11 | 3/11 | 5.39 s |
| Qwen2.5 0.5B | Schema and category meanings | 11/11 | 3/11 | 5.09 s |
| Qwen2.5 1.5B | Schema | 11/11 | 6/11 | 7.25 s |
| Qwen2.5 1.5B | Schema and category meanings | 11/11 | 5/11 | 6.77 s |

The grammar improved structural validity and reduced median request time on these fixtures. The 0.5B model still assigned Work to multiple captures about other categories. The meanings variant left exact matches unchanged on 0.5B and reduced them by one on 1.5B. The tested outputs continue to require individual review. [0.5B schema](benchmark-results/provider-metadata-v2-qwen05-schema-20261124.json) · [1.5B schema](benchmark-results/provider-metadata-v2-qwen15-schema-20261124.json) · [0.5B meanings](benchmark-results/provider-metadata-v2-qwen05-meanings-20261124.json) · [1.5B meanings](benchmark-results/provider-metadata-v2-qwen15-meanings-20261124.json)

Run the benchmark against an explicitly started local llama.cpp endpoint. The optional `--json-object`, `--json-schema` and `--json-schema-meanings` flags reproduce the tested formats.

```sh
TZ=Europe/London dart run tool/benchmark/provider_capture_bench.dart \
  http://127.0.0.1:17860/v1 local-model-alias \
  tool/benchmark/provider_metadata_cases.json /tmp/easy-v2-metadata.json
```
