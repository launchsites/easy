# Native storage write failures

Five Linux processes ran against a private synthetic workspace. They used Easy’s production SQLite and attachment stores, with a bounded WAV fixture and a high-entropy note that forced SQLite to grow its WAL. The largest fixture measurement between processes was 597,508 bytes. [Trace results](benchmark-results/native-storage-faults-20261124.json)

| Phase | Verified result |
| --- | --- |
| Seed | Revision 2, an earlier named checkpoint and one checked WAV were acknowledged. |
| Capacity | A 96 KiB process file-size ceiling produced kernel `EFBIG` on the WAL and the attachment staging payload. Both storage calls rejected. Revision 2 and the earlier WAV were still readable, and the staging directory was cleared. |
| Owner permissions | The kernel denied writes to both fixture directories with `EACCES`. The production workspace opener rejected the protected database, the attachment operation rejected, and a read-only inspection found the same revision and database bytes. |
| Retry | Restored permissions and capacity let the original operation ID commit revision 3. Repeating the operation ID returned revision 3. Two imports of the recovered WAV resolved to one verified payload. |
| Reopen | A fresh process recovered revision 3, the earlier checkpoint, both recordings and their exact digests. |

SQLite integrity, quick and foreign-key checks passed after every phase. This experiment covers the filesystem’s per-file capacity limit and owner-permission denial. The kernel returned `EFBIG` for the capacity case. [Storage worker](../tool/benchmark/storage_capacity_worker_test.dart)

Run from the repository root as an unprivileged user on glibc Linux x86-64 or arm64. Install the locked Flutter dependencies first. Omit `--trace` to run the same checks without syscall tracing. [Fixture runner](../tool/benchmark/native_storage_faults.py)

```sh
flutter pub get --enforce-lockfile
python3 tool/benchmark/native_storage_faults.py \
  --trace "$(command -v strace)" --report native-storage-faults.json
```

## Task inspector on Linux

The packaged `d1ac727` Linux app ran at 1280 × 720 against a fresh synthetic profile. A reader pinned the SQLite WAL while the app process received a 32,992-byte file-size ceiling. Clicking **Mark done** displayed the save error. Five status samples contained no completion confirmation, and SQLite retained the exact revision 1 document and digest. Restoring the ceiling let the same inspector action commit once at revision 2. The task’s other fields and saved note matched the initial document. A newly launched process read the exact revision 2 document, and SQLite’s quick check passed at every observation. [Packaged app results](benchmark-results/native-storage-ui-fault-d1ac727-20261124.json)

The probe uses Xvfb, xdotool, ImageMagick and Tesseract. Give it the unpacked Linux executable and its build verification JSON. It checks the executable and compiled application library hashes before launching a disposable profile. [Inspector probe](../tool/benchmark/native_storage_ui_fault.py)

```sh
python3 tool/benchmark/native_storage_ui_fault.py \
  --app /path/to/unpacked/easy/easy \
  --verification /path/to/verification.json \
  --report native-storage-ui-fault.json
```
