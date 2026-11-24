# Privacy and threat model

Easy opens a local workspace without an account. Workspace records, saved history, and original recordings and photos stay in app storage. Native workspace backups are made on request. Apple Calendar, a model, and a paired device each have their own setup and approval. [Workspace storage](storage-validation.md) · [Native offline validation](native-performance-benchmark.md)

## Model requests

Offline capture processes text on the device. The local model route sends reviewed inputs to a literal loopback address on the device. Choose a runtime you trust, since the process listening on that address controls how it handles the request. A paid API request uses the configured HTTPS endpoint and shows the destination, submitted fields, and estimated reservation before sending. The native transport connects directly, and a redirect ends the request. Routes keep their own provider settings. [Provider configuration](../lib/ai/provider/provider_config.dart) · [Review and dispatch](../lib/ai/ai_runtime.dart) · [Transport tests](../test/ai_provider_test.dart)

You can give separate permission for foreground duration estimates. That approval describes task titles and temporary request identifiers. Optional timing evidence adds prior durations and grouped numeric ranges. Meal photo review has its own approval showing the resized image. Easy builds that image from pixels and removes source metadata before sending. Names, imagery and other details visible in the pixels can remain. [Timing evidence](task-context-validation.md) · [Image preparation](../lib/ai/vision/vision_image_flutter.dart)

Easy stores API keys through the device credential service where available. On Linux with an unavailable Secret Service, the key lasts for the current session. The device ledger is separate from the workspace and its backups. An API request reserves its configured maximum cost before it leaves Easy. The ledger reconciles accepted usage reports and retains the full reservation when usage is unavailable. The provider controls its actual bill and any separate account spending limits. [Credential and ledger storage](../lib/ai/ai_device_state.dart) · [Budget accounting](../lib/ai/ai_budget.dart)

Opening a second window preserves recent reservations while the first window can still settle them. A later settings reload recovers unresolved reservations as maximum-cost entries after three minutes. Easy rechecks the saved allowance after approval and releases a prepared request if the device’s budget month changes before sending. A reply received after midnight still settles in the month reserved when the request was sent. [Concurrency tests](../test/ai_allowance_concurrency_test.dart) · [Transport tests](../test/ai_provider_test.dart)

## Calendar access

On Apple devices, Calendar settings can ask for EventKit permission. The calendar picker lists available sources. Event reads use the calendars selected in Easy and the time window the view needs. A revoked permission clears the feed's cached records and verified coverage. Imported iCalendar files can be read locally and selected for individual Focus views. [Calendar settings](../lib/calendar_sources/calendar_settings_page.dart) · [Calendar feed](../lib/calendar_sources/apple_calendar_feed.dart)

A copy to Apple Calendar requires choosing a writable calendar and confirming the event fields. Updates target the previously linked event and recheck its saved revision. Location and notes on updates are individually selected in the review. Apple Calendar may sync an approved copy using the account you chose. [Copy and update bridge](../apple/EventKitCalendarBridge.swift) · [Calendar time-zone interchange](calendar-time-zone-interchange.md)

## Backups and transfers

Backup export uses a passphrase. Native media backups use Argon2id key derivation and authenticated AES-GCM frames. They optionally include originals referenced by the workspace records. Format validation may stage one decrypted original at a time under a private temporary directory. A completed review retains an encrypted archive. Interrupted operations may leave temporary files for the cleanup review. Restoring records checks the reviewed revision and saves a recovery point. Earlier versions can still retain records removed from the current workspace. [Backup and staging validation](storage-validation.md)

Manual sync pairs two devices by a code you verify on both screens. Encrypted change files travel by the transfer method you choose. Each recipient reviews the merge and chooses which records to apply to the workspace. Revocation stops future accepted transfers from the revoked peer. Earlier files and records can remain on that peer's device. [Manual sync](manual-sync.md)

## Device and service boundaries

Workspace SQLite files and stored originals depend on the operating system and local profile for access protection. Workspace export encryption protects the backup file with its passphrase. Someone with access to the unlocked device or its app files may be able to read records, history, and originals. Periodic automatic estimates and interactive review use the submitted provider's own retention and billing policies. [Native storage implementation](../lib/storage/src/open_native.dart) · [Attachment storage](../lib/storage/src/open_attachment_native.dart)

On Linux the runner masks permissions for the group and other accounts before it opens Flutter. At startup it tightens the regular, owner-controlled Easy application profile in the XDG data directory. An executable-name fallback requires the existing SQLite application identity before Easy tightens its workspace directory and regular, singly linked preference file. The check uses file descriptors opened without following symbolic links. [Linux runner](../linux/runner/main.cc) · [Profile permissions](../linux/runner/profile_permissions.cc)

The Linux release probe started from an inherited `0022` mask and a synthetic `0755` XDG data directory. Fresh and existing Easy profile directories reached `0700`. The new workspace database and WAL both reached `0600`. The existing preference snapshot was preserved under its private profile and all synthetic records reopened successfully. The native file checks also exercise owner read-only permissions and linked paths. [Release probe](../tool/benchmark/linux_profile_permissions.py) · [Probe results](benchmark-results/linux-profile-permissions-20261124.json)

```sh
flutter build linux --release
python3 tool/benchmark/linux_profile_permissions.py --binary build/linux/x64/release/bundle/easy
```
