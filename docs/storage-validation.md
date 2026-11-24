# Local storage validation

Run the focused suites and the scale workload from the repository root.

```sh
flutter test test/storage_workspace_test.dart test/storage_encrypted_backup_test.dart test/storage_attachment_test.dart
flutter test tool/benchmark/storage_scale_test.dart --reporter expanded
```

The scale workload ran on the Linux x86-64 development host on 24 November 2026. The host exposed five logical CPUs and a 16 GiB cgroup memory limit while the app build and other tests were being developed. The fixture held 100,000 tasks, 30,000 events, 50,000 gym sessions, 3,000 notes, and 10,000 opaque meal metadata records. Attachment payload count was zero. The test checked exact workspace JSON after logical export and preview, plus persisted SQLite reopen.

| Step | Elapsed |
| --- | --- |
| Migrate the fixture into SQLite | 3,383 ms |
| Export a logical backup | 3,597 ms |
| Validate and preview the backup | 4,959 ms |
| Close and reopen SQLite | 2,389 ms |

The database occupied 42,291,200 bytes after close. The logical backup occupied 54,745,504 bytes. Timings are host measurements for that fixture. The SQLite work executes in a native worker isolate.

The focused suites cover concurrent writes and revision conflicts, interrupted recovery writes, malformed or modified backup files, an independent encryption fixture, duplicate attachments arriving concurrently, and digest and symlink checks. The attachment format suite uses synthetic media containers and small JPEG and PNG files. A separate local smoke run streamed an 847-byte AAC M4A produced by FFmpeg through storage and verified byte-for-byte readback.
