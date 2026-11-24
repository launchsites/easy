# Test evidence

## Native and platform evidence

The frozen Flutter suite at `8b18bcf` passed 794 tests under `TZ=America/New_York`. Two tests for other host time zones skipped by design. The scopes below include additional native and targeted runs at the revisions identified in their reports.

| Check | Result |
|---|---|
| Linux x86-64 release build | The exact `d1ac727` release was built, archived, extracted and exercised through 38 checks. |
| Offline Linux journey | The frozen release passed sixteen desktop and three mobile checks with IPv4 and IPv6 sockets denied. The synthetic 11,721-record workspace retained its record count and digest. |
| Native release soak | The pinned route test ran for 1,801 seconds. All 156 desktop route probes and 24 hold-and-drag navigation probes passed. The recorded workspace digest was unchanged. |
| Native viewport review | Home, Tasks and Settings exercised at twelve sizes. The compact 320 × 568 Home layout lifted the first visible checkbox above the navigation dock. A Tasks regression covers 568 × 320 landscape. |
| Android API 36 | Offline review APKs built for ARMv7, ARM64 and x86-64. The checks inspect signatures, compiled backup and network rules, and 16 KiB ZIP and ELF load alignment. Development signing is used. |
| macOS and iOS | Dart channel and Swift syntax checks ran on Linux. Apple SDK build, provisioning, device permission and real EventKit verification remain open. |

[Native performance report](native-performance-benchmark.md) · [Release smoke](native-release-smoke.md) · [Android checks](android-validation.md) · [Appearance previews](DESIGN_PREVIEWS.md)

## Data correctness

- Native SQLite exercised migration and version history with 100,000 tasks, 30,000 events, 50,000 gym sessions, 3,000 notes and 10,000 meal metadata records.
- A one-CPU run of 10,000 edits verified four close-and-reopen checkpoints, a named version and an old idempotency key. Save p50 was 53.36 ms and p95 was 112.89 ms.
- A real process interruption stopped a synthetic fixture during its SQLite write. Reopen retained the acknowledged revision, the retry completed once, and integrity checks passed.
- Backup checks cover encrypted wrong-password rejection, stale preview rejection, source-aware selected restores and a separately preserved pre-restore recovery point.
- Native media archives streamed a 256 MiB fixture under a bounded memory profile. Attachment recovery retained the referenced content hash and the prior workspace revision.
- Sync checks cover authenticated local transfer, replay, ordering, revocation, conflicts and transactional rollback. A five-device benchmark replayed 1,024 generated schedules. The Linux Settings route reopened a passphrase-protected journal after process restart.
- Task completion tests inject a rejected write and verify that the saved task stays open. A retry saves once. An older Undo cannot change a newer completion.
- A Linux release run under inherited `0022` verified that the app profile and new database files were private, and that earlier synthetic records reopened correctly.

[Storage validation](storage-validation.md) · [Manual sync validation](manual-sync.md) · [Profile and permission checks](privacy-and-threat-model.md)

## Scheduling and inference

- Five thousand seeded schedule cases check time bounds, dependencies, buffers, effort, split size and ordering. A 20,000-node cycle exercises bounded traversal. The small split oracle exercises 2,500 cases.
- A 12,000-case planner replay preserved 110,769 placement decisions while reducing time spent looking for candidate slots. Daily available time also passed 500 checks against the full planner.
- Ten thousand unchanged capture claims passed validation and ten thousand seeded mutations were withheld. Later model-only suggestions require explicit selection and preserve validated dates and destructive-action boundaries.
- Model and speech benchmarks used pinned open weights and synthetic fixtures. Results document strict schema and factual failures, as well as timing, memory ceilings and cold-start failures.
- Native voice evidence uses an isolated virtual microphone. Held release, slide-left cancel, slide-up lock, resize interruption and live Gym capture were exercised with saved audio and records verified after restart.
- Native local AI testing observed zero automatic requests over 130 seconds minimized. Restoring the window allowed a reviewed duration estimate. A model request in flight was cancelled when the window minimized.
- Mocked provider tests cover request disclosure, paid reservations and settlement, stale responses and cancellation, and derived meal image analysis. No paid provider credentials or user records are needed to run them.

[Local inference measurements](local-inference-benchmark.md) · [Native local model lifecycle](local-ai-setup.md) · [Scheduling performance](scheduling-performance.md)
