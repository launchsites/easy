# Manual sync

The device starts with local records. Open **Settings → Manual sync** to enable it or join another device. The encrypted journal and Easy workspace retain their own revisions and review steps.

## Pair two devices

1. Open an invitation on the first device and share its token directly with the person holding the second device. The invitation contains the public device fingerprint, workspace ID, and a random invitation secret. It expires after five minutes.
2. Open the invitation on the second device and return its response token to the first device. Review the device fingerprints and compare the eight-character code displayed on both devices.
3. Confirm the comparison on each device, exchange the two approval receipts, then accept each reviewed pairing. Store the resulting pair key through the selected device vault.

The invitation secret is 32 random bytes. The two ephemeral X25519 keys are bound to the invitation and response by Ed25519 proofs. HKDF-SHA256 derives a bundle key, a confirmation key and a comparison code from the shared secret, invitation secret and transcript. Each approval receipt includes a transcript-bound MAC and the approving device's signature. The five-minute invitation and local one-use state constrain replay. The fingerprints and comparison code are presented for in-person verification. This construction uses the cryptography package and needs an independent protocol review before adding discovery or network transport. [X25519](https://www.rfc-editor.org/rfc/rfc7748) · [HKDF](https://www.rfc-editor.org/rfc/rfc5869) · [Ed25519](https://www.rfc-editor.org/rfc/rfc8032)

## Local keys and bundles

On Linux, a passphrase unlocks the local sync vault for the current session. Apple and Android builds use their system credential service. The vault stores the installation identity, journal encryption keys and pair keys. The Linux vault wraps its credential format in the Argon2id and AES-GCM backup envelope. Its writes use a file lock, flushed ciphertext staging, and an atomic rename. Reopening requires the existing vault and journal.

The native installation marker records the workspace ID and setup phase. First enablement takes a profile lock after any passphrase prompt and reads the marker again before creating credentials or a journal. A successful reopen of an older preference marker migrates it to the native marker file.

A journal approval binds the peer's public fingerprint to an immutable key ID. A competing approval can leave its own candidate in protected storage while the committed key remains attached to the active grant. Revocation removes journal permission before cleaning up the vault entry. If vault cleanup fails, the caller can retry while the earlier permission stays revoked. Copies already exported remain with their recipients.

Choose an approved device and open **Choose records** to search saved tasks, calendar events and notes. Check the rows to stage in the journal. **Export changes** then creates an authenticated encrypted file with the journal changes that device is missing. The receiving device can share an encrypted progress code after saving each bundle. The next export uses that device-specific code to continue from its saved watermark.

Import preview checks the workspace, sender, recipient, key, causal dependencies, and conflict states. Saving the reviewed bundle to the journal requires separate consent for removals or conflicts. **Review workspace changes** shows additions, replacements and removals alongside available local and incoming details. You choose which changes to apply. The journal and workspace revisions must match the review, and an interrupted or repeated apply can reuse its recovery point. Reopening an accepted bundle reveals its current journal records for another workspace review.

The supported records are standalone tasks, events and notes. Task dependencies and structured note links need their referenced records on the destination device or in the same selection. Recurring templates, mirrored or read-only calendar events, planner blocks, attachments, app settings, and records with unrecognized fields stay local. The chooser stages records that exist in the local workspace. Receiving a removal requires a matching saved local version and a review that preserves remaining references.

## Validation

```sh
flutter test test/sync_pairing_test.dart test/manual_sync_workspace_test.dart \
  test/manual_sync_page_test.dart test/manual_sync_installation_test.dart \
  test/sync_password_vault_test.dart test/sync_password_vault_prompt_test.dart \
  test/sync_journal_test.dart test/workspace_sync_test.dart
```

The tests exercise the code exchange, stale and competing approvals, locked-vault recovery, revoke-before-cleanup, ciphertext transfer and directional progress between synthetic native stores, and passphrase file reopening and corruption checks. They also cover phase-by-phase selection, linked records and protected deletions, retry after intervening edits, exact recovery in SQLite and the preference store, and release of the SQLite journal lock after a failed workspace commit. The paired-device and staging widgets run at 320 pixels with 135% text scaling. The system vault adapter is exercised through the plugin's test backend. Platform keychains and in-person token scanning need separate real-device validation.

A native test stages 54 synthetic notes carrying about 1.2 MB of text. The first encrypted file reaches the byte limit before the record-count limit. The receiver rejects a modified file, saves the valid bundle, and both journal owners reopen from their original credentials. An authenticated progress code fetches the next file. The final workspace matches every source note and retains the first page as its recovery point. The test completed in about 13 seconds on the shared Linux host with affinity limited to one logical CPU, excluding Flutter test startup. [Transport test](../test/manual_sync_workspace_test.dart)

Four independent native SQLite journals also converge after partitioned note edits and a concurrent deletion. The test verifies that a relayed author must be approved, removals and conflicts require separate review, a process-session preview expires on reopen, replay preserves the revision, and a reviewed restore resolves the conflict without losing the note body. Revocation rejects both direct and relayed new changes from the revoked device. [Four-peer test](../test/manual_sync_workspace_test.dart)

The AOT causal-register benchmark generated 64 five-device histories with temporary partitions, concurrent edits, tombstones and restores. Across 1,024 seeded delivery orders, all resulting records and watermarks matched their chronological reference. The run applied 40,960 unique changes, handled 10,240 duplicate deliveries and revisited delayed dependencies. It took 35.47 seconds and peaked at 16.32 MiB RSS on one logical CPU with a 768 MiB address-space limit. [Runner](../tool/benchmark/sync_partition_bench.dart) · [Raw results](benchmark-results/sync-partitions-epyc-20261124.json)

A Linux release probe used two independent process launches and D-Bus sessions against a disposable GNOME Keyring profile. The system vault retained the installation identity, sealed journal and peer key across the restart. A separate profile with no Secret Service verified the same restart using the encrypted passphrase vault and rejected a wrong passphrase. The passphrase prompt tests cover a 320-pixel portrait viewport at 135% text and a 568×320 right-to-left landscape viewport at 200% text, both with a simulated keyboard. They also confirm that cancellation and an unlock attempt with a missing vault preserve the saved configuration for recovery. [Vault tests](../test/sync_password_vault_test.dart) · [Prompt tests](../test/sync_password_vault_prompt_test.dart)

The invitation dialog keeps its field width when pasting a 3,083-character code. The test covers both a 1440-pixel desktop and a 320-pixel display at 200% text with a simulated keyboard. [Dialog layout test](../test/manual_sync_token_dialog_test.dart)

The Linux release at `74a9fb8` passed the complete Settings setup and restart in a disposable 1280×720 X11 profile without a Secret Service. Cancelling first setup left sync state absent. Enabling produced a valid SQLite journal and an encrypted vault. A fresh app process retained its locked state after cancellation, rejected a wrong passphrase and opened the original vault with the right one. The vault bytes and workspace revision and digest matched the pre-restart values. [Native runner](../tool/benchmark/native_sync_settings.py) · [Raw results](benchmark-results/native-sync-settings-epyc-20261124.json)

The Linux release at `deee4ba` also completed first setup from two separate app processes sharing one disposable profile. The processes opened their setup prompts before either approved. Both then displayed the same device fingerprint and produced one ready marker and one integrity-checked journal. A third process opened the same identity and preserved the earlier vault bytes and workspace. [Native race runner](../tool/benchmark/native_sync_installation_race.py) · [Raw results](benchmark-results/native-sync-installation-race-epyc-20261124.json)

The same release was interrupted after publishing its pending setup marker. The surviving process completed that exact workspace ID, produced an integrity-checked journal and reopened the same identity after another restart. [Process interruption results](benchmark-results/native-sync-installation-interrupted-epyc-20261124.json)
