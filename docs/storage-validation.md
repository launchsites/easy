# Local storage validation

Run the focused suites and the scale workload from the repository root.

```sh
flutter test test/storage_workspace_test.dart test/storage_history_test.dart test/storage_history_page_test.dart test/storage_encrypted_backup_test.dart test/storage_attachment_test.dart test/sync_journal_test.dart test/workspace_sync_test.dart
flutter test tool/benchmark/storage_scale_test.dart --reporter expanded
EASY_STORAGE_EDITS=10000 taskset -c 4 flutter test tool/benchmark/storage_churn_test.dart --reporter expanded
```

The scale workload ran on the Linux x86-64 development host on 24 November 2026. The host exposed five logical CPUs and a 16 GiB cgroup memory limit while the app build and other tests were being developed. The fixture held 100,000 tasks, 30,000 events, 50,000 gym sessions, 3,000 notes, and 10,000 opaque meal metadata records. Attachment payload count was zero. The test checked exact workspace JSON after logical export and preview, plus persisted SQLite reopen.

| Step | Original SQLite schema | Compressed chunk schema |
| --- | --- | --- |
| Migrate the fixture into SQLite | 3,383 ms | 3,519 ms |
| Export a logical backup | 3,597 ms | 4,348 ms |
| Validate and preview the backup | 4,959 ms | 9,336 ms |
| Close and reopen SQLite | 2,389 ms | 4,272 ms |
| Database bytes after close | 42,291,200 | 3,809,280 |
| Logical backup bytes | 54,745,504 | 54,745,504 |

Both timing samples were collected on a shared host alongside development work. The SQLite work executes in a native worker isolate.

## Sustained edits

The churn workload ran with affinity pinned to one logical AMD EPYC 9V74 CPU on the same host. It committed 10,000 task changes on a 797,774-byte workspace with 2,400 tasks, 1,200 events, 500 notes, and 400 gym sessions. It reopened the database after every 2,500 commits, checked exact record bytes, recovered the first named checkpoint, and confirmed idempotency for the oldest retried operation. SQLite integrity and foreign-key checks passed.

| Metric | Observed |
| --- | --- |
| Total edit loop | 639.8 s |
| Save latency p50 | 53.361 ms |
| Save latency p95 | 112.887 ms |
| Save latency p99 | 231.752 ms |
| Retained history points | 9 |
| Database bytes after close | 393,216 |
| Peak sampled WAL bytes | 2,228,952 |

The WAL sample interval was 250 commits. A separate test held a shared WAL reader open while the writer compacted history. The reader kept its old snapshot until it committed. Retention prunes transient revisions and unreachable chunks under configurable code limits for recent, timed, and named history. Older SQLite files can reuse reclaimed pages.

The focused suites cover concurrent writes and revision conflicts, interrupted recovery and compaction transactions, selective restore, malformed or modified backup files, independent encryption fixtures, duplicate attachment imports, and digest and symlink checks. History restores saved Easy records and settings, with media continuing to use its local storage. Paired bundles use explicit device grants and authenticated import previews. The attachment format suite uses synthetic media containers and small JPEG and PNG files. A separate local smoke run streamed an 847-byte AAC M4A produced by FFmpeg through storage and verified byte-for-byte readback.
