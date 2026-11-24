# Local AI in Easy

Easy can use a model server running on the same device. Start the server yourself and choose **Local** in **Settings → AI assistance**. Easy keeps offline capture and manual planning available when the endpoint is unavailable.

## Start a Linux CPU runtime

Download the Linux build of llama.cpp and a trusted instruct GGUF file. Keep both outside the Easy repository. The command below was checked with llama.cpp b12657 and Qwen2.5-1.5B-Instruct Q4_K_M. The downloads and checksums are in the benchmark instructions. [Pinned runtime and model](local-inference-benchmark.md#reproduce)

Set the paths to your extracted executable and downloaded model. Leave the server running in this terminal while using it in Easy.

```sh
easy_llama_server=/absolute/path/to/llama-server
easy_local_model=/absolute/path/to/qwen2.5-1.5b-instruct-q4_k_m.gguf
easy_local_port=11434

"$easy_llama_server" --model "$easy_local_model" \
  --host 127.0.0.1 --port "$easy_local_port" --alias easy-local \
  --ctx-size 4096 --parallel 1 --threads 2 --threads-batch 2 \
  --gpu-layers 0 --poll 0 --reasoning off --no-warmup --offline \
  --no-ui --no-slots --cors-origins "http://127.0.0.1:$easy_local_port" \
  --no-cors-credentials
```

From a second terminal, check that the service is ready and advertises `easy-local`.

```sh
curl --noproxy '*' -fsS http://127.0.0.1:11434/health
curl --noproxy '*' -fsS http://127.0.0.1:11434/v1/models
```

Use these settings in Easy. If you chose a different unused port, enter it in **Base URL** and both checks above.

| Setting | Value |
| --- | --- |
| Route | **Local** |
| Base URL | `http://127.0.0.1:11434/v1` |
| Model | `easy-local` |
| Request limits → Maximum input tokens | `3072` |
| Request limits → Maximum output tokens | `256` |

The **Local** route accepts literal `127.0.0.1` and `[::1]` HTTP addresses. Easy adds `/chat/completions` to the base URL and sends no API credential. Select **Save settings**. In capture review, enter a short synthetic item and choose **Review with AI**. **Confirm local requests** shows the fields being sent before dispatch. **Include optional context** separately allows fields such as custom category labels and eligible timing history.

**Structured capture replies** requests JSON Schema from compatible local servers such as the pinned llama.cpp build. Existing Local settings leave this option off. It narrows capture replies to the offered fields, and Easy still asks you to review the result and confirm each suggested change. Turn the option off if your server rejects the format.

Local requests use the model server's memory and CPU. **Suggest durations** enables estimate review. **Use spare capacity** opts into preparing estimates while the workspace is open and idle. **Use more foreground time** gives the local scheduler up to six estimate attempts per day. Easy cancels active local inference when the app backgrounds. Stop the separate server with `Ctrl+C` to reclaim its memory.

The supplied Qwen checkpoint accepts text. Meal photo suggestions require a separate compatible vision model. The capture validator can discard model replies that omit evidence or use an unsupported shape. The saved capture remains available for manual review. [Capture and estimate results](local-inference-benchmark.md)

## CPU and memory observations

The controlled profiles used real CPU inference on a shared Linux VM. At a 512-token context, Qwen2.5 0.5B peaked around 602 MiB RSS on one logical CPU with a 1.5 GiB address-space limit and failed to initialize under 1 GiB. Qwen2.5 1.5B peaked around 1.74 GiB RSS in its one-CPU profile. Qwen3 4B could not map under a 2 GiB address-space ceiling. Its successful one-CPU profile peaked around 4.1 GiB. Memory grows with the runtime settings and model size. [CPU and memory profiles](local-inference-benchmark.md#measured-results)

In two six-minute desktop runs, the same Easy release navigated the same 11,721-record fixture on one logical CPU. The mixed run shared that CPU with a separate Qwen2.5 0.5B process. A navigation cycle switched and scrolled all desktop destinations before resizing. Selected-route and mobile orbit checks sampled every fifth cycle.

| One-CPU Easy run | Navigation cycles | Selected desktop routes | Mobile orbit checks | App peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Control, 363.85 s | 50 | 40/40 | 10/10 | 454 MiB |
| With model work, 365.79 s | 46 | 40/40 | 10/10 | 454 MiB |

Both runs retained the exact workspace revision and digest, passed SQLite integrity checks and had zero OOM kills. The containing 483.6-second synthetic model soak completed 66 schema-constrained requests with a 7.59-second median and 11.26-second p95. Twelve replies matched all expected fields. The model load was a separate authenticated local benchmark, and the Easy window ran its normal navigation during the overlap. [Mixed and control evidence](benchmark-results/native-local-contention-epyc-20261124.json)

The production structured capture option was exercised with Qwen2.5 1.5B on two logical CPUs during other workspace activity. The server used a 3 GiB address-space limit, a 4,096-token context and a 160-token response limit. Three of 11 eligible requests returned a valid draft within Easy's 30-second deadline. Two matched the expected metadata and eight requests timed out. The three accepted responses had a 21.76-second median. Eight offline controls made zero provider requests. [Production capture evidence](benchmark-results/provider-metadata-qwen15-production-schema-20261124.json)
