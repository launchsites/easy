# Manual sync

The device starts with local records. The host opens a manual sync workspace after setup or joining. The encrypted journal and Easy workspace retain their own revisions and review steps.

## Pair two devices

1. Open an invitation on the first device and share its token directly with the person holding the second device. The invitation contains the public device fingerprint, workspace ID, and a random invitation secret. It expires after five minutes.
2. Open the invitation on the second device and return its response token to the first device. Review the device fingerprints and compare the eight-character code displayed on both devices.
3. Confirm the comparison on each device, exchange the two approval receipts, then accept each reviewed pairing. Store the resulting pair key through the selected device vault.

The invitation secret is 32 random bytes. The two ephemeral X25519 keys are bound to the invitation and response by Ed25519 proofs. HKDF-SHA256 derives a bundle key, a confirmation key and a comparison code from the shared secret, invitation secret and transcript. Each approval receipt includes a transcript-bound MAC and the approving device's signature. The five-minute invitation and local one-use state constrain replay. The fingerprints and comparison code are presented for in-person verification. This construction uses the cryptography package and needs an independent protocol review before adding discovery or network transport. [X25519](https://www.rfc-editor.org/rfc/rfc7748) · [HKDF](https://www.rfc-editor.org/rfc/rfc5869) · [Ed25519](https://www.rfc-editor.org/rfc/rfc8032)

## Local keys and bundles

The system vault stores the installation identity, journal encryption keys and pair keys. The optional native password vault uses the Argon2id and AES-GCM backup envelope around its own credential format. Its writes use a file lock, flushed ciphertext staging, and an atomic rename. The password unlocks this local vault for the current session. Reopening requires the existing vault and journal.

A journal approval binds the peer's public fingerprint to an immutable key ID. A competing approval can leave its own candidate in protected storage while the committed key remains attached to the active grant. Revocation removes journal permission before cleaning up the vault entry. If vault cleanup fails, the caller can retry while the earlier permission stays revoked. Copies already exported remain with their recipients.

Choose an approved device and open **Choose records** to search saved tasks, calendar events and notes. Check the rows to stage in the journal. **Export changes** then creates an authenticated encrypted file with the journal changes that device is missing. The receiving device can share an encrypted progress code after saving each bundle. The next export uses that device-specific code to continue from its saved watermark.

Import preview checks the workspace, sender, recipient, key, causal dependencies, and conflict states. Saving the reviewed bundle to the journal requires separate consent for removals or conflicts. **Review workspace changes** shows additions, replacements and removals alongside available local and incoming details. You choose which changes to apply. The journal and workspace revisions must match the review, and an interrupted or repeated apply can reuse its recovery point. Reopening an accepted bundle reveals its current journal records for another workspace review.

The supported records are standalone tasks, events and notes. Task dependencies and structured note links need their referenced records on the destination device or in the same selection. Recurring templates, mirrored or read-only calendar events, planner blocks, attachments, app settings, and records with unrecognized fields stay local. The chooser stages records that exist in the local workspace. Receiving a removal requires a matching saved local version and a review that preserves remaining references.

## Validation

```sh
flutter test test/sync_pairing_test.dart test/manual_sync_workspace_test.dart test/manual_sync_page_test.dart test/sync_password_vault_test.dart test/sync_journal_test.dart test/workspace_sync_test.dart
```

The tests exercise the code exchange, stale and competing approvals, locked-vault recovery, revoke-before-cleanup, ciphertext transfer and directional progress between synthetic native stores, and passphrase file reopening and corruption checks. They also cover phase-by-phase selection, linked records and protected deletions, retry after intervening edits, exact recovery in SQLite and the preference store, and release of the SQLite journal lock after a failed workspace commit. The paired-device and staging widgets run at 320 pixels with 135% text scaling. The system vault adapter is exercised through the plugin's test backend. Platform keychains and in-person token scanning need separate real-device validation.
