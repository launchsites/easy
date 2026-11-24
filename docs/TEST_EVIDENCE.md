# Test evidence

## Native and platform evidence

The frozen Flutter suite at `96dc0f3` passed 830 tests under `TZ=Europe/London`. Seven checks for other host time zones skipped by design. Strict analysis and four native project declaration checks passed. An earlier hosted run passed full Linux verification including 53 New York and 34 Lord Howe daylight-saving checks. [Hosted verification](https://github.com/launchsites/easy/actions/runs/45334600558)

| Check | Result |
|---|---|
| Linux x86-64 release build | The exact `6f18fe9` release was built, archived, extracted and exercised through 38 checks. |
| Offline Linux journey | The frozen release passed sixteen desktop and three mobile checks with IPv4 and IPv6 sockets denied. The synthetic 11,721-record workspace retained its record count and digest. |
| Native release soak | The pinned route test ran for 1,801 seconds. All 156 desktop route probes and 24 hold-and-drag navigation probes passed. The recorded workspace digest was unchanged. |
| Native viewport review | Home, Tasks and Settings exercised at twelve sizes. The compact 320 × 568 Home layout lifted the first visible checkbox above the navigation dock. A Tasks regression covers 568 × 320 landscape. |
| Android API 36 | Offline review APKs built for ARMv7, ARM64 and x86-64. Checks inspect development signatures, compiled backup and network rules, and 16 KiB ZIP and ELF load alignment. A hosted AOSP emulator launched the non-debuggable x86-64 release and verified its private empty workspace. [Emulator run](https://github.com/launchsites/easy/actions/runs/45337863946) |
| macOS and iOS | Hosted Xcode built the iOS simulator target and unsigned macOS release. Dart channel and Swift syntax checks also passed. Provisioning, physical device permissions and real EventKit account verification remain open. [Apple SDK run](https://github.com/launchsites/easy/actions/runs/45334132108) |

[Native performance report](native-performance-benchmark.md) · [Release smoke](native-release-smoke.md) · [Android checks](android-validation.md) · [Appearance previews](DESIGN_PREVIEWS.md)

## Data correctness

- Native SQLite exercised migration and version history with 100,000 tasks, 30,000 events, 50,000 gym sessions, 3,000 notes and 10,000 meal metadata records.
- A one-CPU run of 10,000 edits verified four close-and-reopen checkpoints, a named version and an old idempotency key. Save p50 was 53.36 ms and p95 was 112.89 ms.
- A real process interruption stopped a synthetic fixture during its SQLite write. Reopen retained the acknowledged revision, the retry completed once, and integrity checks passed.
- A Linux file-size ceiling and owner permissions produced actual write errors. The packaged task inspector acknowledged completion only after a successful retry. [Native storage faults](native-storage-faults.md)
- Backup checks cover encrypted wrong-password rejection, stale preview rejection, source-aware selected restores and a separately preserved pre-restore recovery point.
- Native media archives streamed a 256 MiB fixture under a bounded memory profile. Attachment recovery retained the referenced content hash and the prior workspace revision.
- Sync checks cover authenticated local transfer, replay, ordering, revocation, conflicts and transactional rollback. A five-device benchmark replayed 1,024 generated schedules. Two paired Linux profiles exchanged a reviewed file, applied only the selected task, and recovered it after restart. [Native sync transfer](manual-sync.md)
- Task completion tests inject a rejected write and verify that the saved task stays open. A retry saves once. An older Undo cannot change a newer completion.
- A live Linux workout kept its recorded actuals and open logger when Finish hit a real SQLite WAL write failure. Retrying saved the finished workout and its follow-up draft together. [Native release checks](native-release-smoke.md)
- A Linux release run under inherited `0022` verified that the app profile and new database files were private, and that earlier synthetic records reopened correctly.

[Storage validation](storage-validation.md) · [Manual sync validation](manual-sync.md) · [Profile and permission checks](privacy-and-threat-model.md)

## Scheduling and inference

- Five thousand seeded schedule cases check time bounds, dependencies, buffers, effort, split size and ordering. A 20,000-node cycle exercises bounded traversal. The small split oracle exercises 2,500 cases.
- A 12,000-case planner replay preserved 110,769 placement decisions while reducing time spent looking for candidate slots. Daily available time also passed 500 checks against the full planner.
- One million unchanged two-item capture batches passed validation and one million seeded mutations were withheld. The AOT run used one CPU with a 256 MiB address-space limit. Later model-only suggestions require explicit selection. [Large validator run](benchmark-results/capture-validation-million-20261124.json)
- Model and speech benchmarks used pinned open weights and synthetic fixtures. Results document strict schema and factual failures, as well as timing, memory ceilings and cold-start failures.
- Forty-eight controlled loopback calls compared point and range prompts with two pinned Qwen models under one- and two-CPU bounds. The models returned no validated ranges. Controlled provider replies independently verified range review. [Local model measurements](local-inference-benchmark.md)
- Native voice evidence uses an isolated virtual microphone. Held release, slide-left cancel, slide-up lock, resize interruption and live Gym capture were exercised with saved audio and records verified after restart.
- Native local AI testing observed zero automatic requests over 130 seconds minimized. Restoring the window allowed a reviewed duration estimate. A model request in flight was cancelled when the window minimized.
- Mocked provider tests cover request disclosure, paid reservations and settlement, stale responses and cancellation, and derived meal image analysis. No paid provider credentials or user records are needed to run them.
- Two native Flutter tester processes shared one private SQLite allowance at `8e3dbac`. Synthetic replies settled in reverse order for an exact total of 11 micro-pounds. Advancing the test clock past midnight during an acknowledgement released the unused reservation before transport. The new month admitted one 9,216-micro-pound request and blocked a second at the remaining allowance. In a later phase, disabling API in the other process during an acknowledgement also released the unused reservation before transport. [Process runner](../tool/benchmark/ai_allowance_process.py) · [Raw results](benchmark-results/ai-allowance-process-epyc-20261124.json)
- The paid allowance settings test at 320 × 500, right-to-left direction and 200% text lowers the cap below existing usage with a simulated keyboard. It verifies that the remainder reaches zero and that reloading after a stale save shows the current allowance.
- A published-advisory query on 24 November 2026 matched none of the 119 hosted package versions in the Dart dependency lockfile. The query used exact locked versions. [OSV database](https://osv.dev/) · [Dart lockfile](../pubspec.lock)

[Local inference measurements](local-inference-benchmark.md) · [Native local model lifecycle](local-ai-setup.md) · [Scheduling performance](scheduling-performance.md)
