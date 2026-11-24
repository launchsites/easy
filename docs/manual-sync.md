# Manual sync foundation

The device starts with local records. The host opens a manual sync workspace only for an explicit setup or join action. The sealed journal and the normal Easy workspace remain separate. Bundle preview shows affected records and conflicts before commit so a host can review how those records will be used.

## Pair two devices

1. Open an invitation on the first device and share its token directly with the person holding the second device. The invitation contains the public device fingerprint, workspace ID, and a random invitation secret. It expires after five minutes.
2. Open the invitation on the second device and return its response token to the first device. Review the device fingerprints and compare the eight-character code displayed on both devices.
3. Confirm the comparison on each device, exchange the two approval receipts, then accept each reviewed pairing. Store the resulting pair key through the selected device vault.

The invitation secret is 32 random bytes. The two ephemeral X25519 keys are bound to the invitation and response by Ed25519 proofs. HKDF-SHA256 derives a bundle key, a confirmation key and a comparison code from the shared secret, invitation secret and transcript. Each approval receipt includes a transcript-bound MAC and the approving device's signature. The five-minute invitation and local one-use state constrain replay. The fingerprints and comparison code are presented for in-person verification. This construction uses the cryptography package and needs an independent protocol review before adding discovery or network transport. [X25519](https://www.rfc-editor.org/rfc/rfc7748) · [HKDF](https://www.rfc-editor.org/rfc/rfc5869) · [Ed25519](https://www.rfc-editor.org/rfc/rfc8032)

## Local keys and bundles

The system vault stores the installation identity, journal encryption keys and pair keys. The optional native password vault uses the Argon2id and AES-GCM backup envelope around its own credential format. Its writes use a file lock, flushed ciphertext staging, and an atomic rename. The password unlocks this local vault for the current session. Reopening requires the existing vault and journal.

A journal approval binds the peer's public fingerprint to an immutable key ID. A competing approval can leave its own candidate in protected storage while the committed key remains attached to the active grant. Revocation removes journal permission before cleaning up the vault entry. If vault cleanup fails, the caller can retry while the earlier permission stays revoked. Copies already exported remain with their recipients.

Choose an approved device for export or import. Files contain authenticated encrypted batches with signed, bounded changes. The receiving device can share an encrypted progress code after saving each bundle. The next export uses that device-specific code to continue from its saved watermark.

Import preview checks the workspace, sender, recipient, key, causal dependencies, and conflict states. Commit uses the reviewed revision and requires separate consent for removals or conflicts. Reviewed journal records can then be selected for a separate workspace projection. Projection previews bind the workspace and sync revisions, and an operation ID lets a confirmed workspace restore be retried with its recovery point intact. Reopening an accepted bundle reveals its current journal records for another workspace review.

## Validation

```sh
flutter test test/sync_pairing_test.dart test/manual_sync_workspace_test.dart test/manual_sync_page_test.dart test/sync_password_vault_test.dart test/sync_journal_test.dart test/workspace_sync_test.dart
```

The tests exercise the code exchange, stale and competing approvals, locked-vault recovery, revoke-before-cleanup, ciphertext transfer and directional progress between two synthetic native stores, and passphrase file reopening and corruption checks. The pairing widget test uses a 320-pixel viewport with 135% text scaling. A separate test reviews a conflicting bundle and projects only a selected record before confirming revocation. The system vault adapter is exercised through the plugin's test backend. Access to platform keychains and in-person token scanning needs separate real-device validation.
