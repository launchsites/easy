# Test evidence

## Native and platform evidence

| Check | Result |
|---|---|
| Linux x86-64 release build | `flutter build linux --no-pub` passed for the integrated `8670be6` development snapshot. |
| Offline Linux journey | The frozen release passed sixteen desktop and three mobile checks with IPv4 and IPv6 sockets denied. The synthetic 11,721-record workspace retained its record count and digest. |
| Native viewport review | Home, Tasks and Settings exercised at twelve sizes. The compact 320 × 568 Home layout lifted the first visible checkbox above the navigation dock. A Tasks regression covers 568 × 320 landscape. |
| Android API 36 | Release Flutter AOT and CMake configuration passed offline for ARMv7, ARM64 and x86-64. Build tools 36.0.0 and NDK r28c were used. Maven dependency downloads blocked packaged APKs and Gradle lint in this run. |
| macOS and iOS | Dart channel and Swift syntax checks ran on Linux. Apple SDK build, provisioning, device permission and real EventKit verification remain open. |

[Native performance report](native-performance-benchmark.md)

## Data correctness

- Native SQLite exercised migration and version history with 100,000 tasks, 30,000 events, 50,000 gym sessions, 3,000 notes and 10,000 meal metadata records.
- A one-CPU run of 10,000 edits verified four close-and-reopen checkpoints, a named version and an old idempotency key. Save p50 was 53.36 ms and p95 was 112.89 ms.
- A real process interruption stopped a synthetic fixture during its SQLite write. Reopen retained the acknowledged revision, the retry completed once, and integrity checks passed.
- Backup checks cover encrypted wrong-password rejection, stale preview rejection, source-aware selected restores and a separately preserved pre-restore recovery point.
- Sync checks cover authenticated local transfer, replay, ordering, revocation, conflicts and transactional rollback with synthetic records.

[Storage validation](storage-validation.md)

## Scheduling and inference

- Five thousand seeded schedule cases check time bounds, dependencies, buffers, effort, split size and ordering. A 20,000-node cycle exercises bounded traversal. The small split oracle exercises 2,500 cases.
- Ten thousand unchanged capture claims passed validation and ten thousand seeded mutations were withheld. Later model-only suggestions require explicit selection and preserve validated dates and destructive-action boundaries.
- Model and speech benchmarks used pinned open weights and synthetic fixtures. Results document strict schema and factual failures, as well as timing, memory ceilings and cold-start failures.
- Mocked provider tests cover request disclosure, paid reservations and settlement, stale responses and cancellation, and derived meal image analysis. No paid provider credentials or user records are needed to run them.

[Local inference measurements](local-inference-benchmark.md)
