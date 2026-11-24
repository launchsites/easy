# Local storage validation

Run the focused suites and the scale workload from the repository root.

```sh
flutter test test/storage_workspace_test.dart test/storage_history_test.dart test/storage_history_page_test.dart test/storage_encrypted_backup_test.dart test/storage_attachment_test.dart test/sync_journal_test.dart test/workspace_sync_test.dart
flutter test test/storage_media_backup_test.dart test/storage_media_staging_test.dart test/storage_backup_page_test.dart
flutter test tool/benchmark/storage_scale_test.dart --reporter expanded
EASY_STORAGE_EDITS=10000 taskset -c 4 flutter test tool/benchmark/storage_churn_test.dart --reporter expanded
bash tool/benchmark/check_storage_crash.sh
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

The Linux crash harness used a synthetic workspace and detected its held SQLite write lock before stopping the Flutter test process. The next process opened the last acknowledged version, verified the in-flight mutation had rolled back, retried it with the same operation ID, recovered the named version, and passed the integrity checks.

The focused suites cover concurrent writes and revision conflicts, interrupted recovery and compaction transactions, selective restore, malformed or modified backup files, independent encryption fixtures, duplicate attachment imports, and digest and symlink checks. History restores saved Easy records and settings, with media continuing to use its local storage. Paired bundles use explicit device grants and authenticated import previews. The attachment format suite uses synthetic media containers and small JPEG and PNG files. A separate local smoke run streamed an 847-byte AAC M4A produced by FFmpeg through storage and verified byte-for-byte readback.

## Portable media backups

Encrypted export starts with workspace records. On native devices the export dialog can also include original voice recordings and meal photos referenced by those records. The Open action recognizes both existing record backups and the media format. The restore preview lists the unique original files and waits for confirmation before publishing them. [Backup page](../lib/storage/workspace_backup_page.dart)

The media archive authenticates 64 KiB frames with AES-GCM. An Argon2id passphrase key and a separate derivation context protect each archive. The authenticated manifest binds the logical backup and its exact set of referenced original files by SHA-256, format and length. Matching references share one archived copy. Frame validation starts during input streaming. The file count and byte limits apply to the manifest and the source stream. [Media archive](../lib/storage/media_backup.dart)

The review holds an encrypted archive in a private temporary directory. Format validation creates and removes one temporary original at a time. Confirming restore checks the reviewed revision and publishes verified originals by content ID before the workspace transaction. The transaction records the prior workspace and can be retried with the same operation ID. Interrupted publication can leave verified unreferenced originals for a later retry. [Restore implementation](../lib/storage/src/open_media_backup_native.dart)

Tests verified exact original bytes with a 24 MiB streamed recording, shared references, early rejection of bad passphrases, invalid manifests, truncation, changed tags, altered review data, and partial publication followed by retry. The restore tests also check recovery and SQLite foreign keys. The 320px page test exercises export, preview, cancellation and confirmation without buffering an entire attachment bundle inside the page. [Archive tests](../test/storage_media_backup_test.dart) · [Backup page tests](../test/storage_backup_page_test.dart)

An AOT frame workload verified 64 MiB of synthetic bytes by SHA-256. The scratch harness used the frame codec from commit `74aa8d0` with its relative imports retargeted and the unchanged 192 MiB record-format limit inlined for standalone Dart. The workload includes key derivation, frame I/O and verification. It excludes native pickers, SQLite and attachment parsing.

| CPU affinity | Seal and write | Read and verify | Process peak RSS |
| --- | --- | --- | --- |
| One logical CPU, first run | 14.40 s | 13.29 s | 121.7 MiB |
| Five logical CPUs | 8.52 s | 7.86 s | 123.9 MiB |
| One logical CPU, second run | 14.58 s | 7.09 s | 144.6 MiB |

A 256 MiB run with one logical CPU wrote the archive in 60.35 s, read and verified it in 64.81 s, matched SHA-256 and peaked at 132.6 MiB RSS. The measurements share the Linux host with other development work. CPU affinity constrains the entire benchmark process, including the encryption worker. [Frame codec](../lib/storage/src/media_backup_frames.dart)

## Temporary media files

SQLite keeps the current workspace and automatic or named history in its revision tables. The last recovery point is a separate logical backup. Each can resolve the same original capture or meal photo through its SHA-256 content ID. Attachment publication can also precede the workspace commit, so an original with no current reference can still belong to a pending save. [Workspace store](../lib/storage/src/sqlite_store.dart) · [Attachment store](../lib/storage/src/open_attachment_native.dart)

The cleanup review targets marked staging folders from interrupted imports and backups. Published SHA-256 folders lie outside that namespace, protecting originals reachable from any recoverable version. Each active stage holds a file lease. The review checks owner process and lease state, then records bounded file metadata. Confirmation checks the reviewed candidates again and clears at most 32 stages from each storage area. A renamed folder left by interrupted cleanup can be reviewed on the next attempt. [Staging implementation](../lib/storage/src/media_staging_native.dart)

The native test starts and kills a synthetic Dart process with a live import lease. It verifies that the active stage stays out of the review and that the abandoned bytes can be cleared after exit. The test also reopens exact originals linked to the working revision, a named history point and recovery. The page test verifies both cancellation and explicit confirmation. [Staging tests](../test/storage_media_staging_test.dart) · [Backup page tests](../test/storage_backup_page_test.dart)
