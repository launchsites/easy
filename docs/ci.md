# Continuous integration

**Verification** runs on pull requests and pushes to `main`. It checks out the requested revision, verifies Flutter 3.50.1 against its upstream commit, and restores packages from the checked-in `pubspec.lock`. The Linux runner analyzes Dart, runs the native source checks and full Flutter suite, checks daylight-saving transitions in New York and Lord Howe, and compiles the Linux release. [Verification workflow](../.github/workflows/verification.yml) · [SDK bootstrap](../.github/scripts/bootstrap-flutter.sh)

An active `main` run can finish while the newest push waits. Each new pull request revision cancels the previous run for that pull request.

**Apple SDK check** is available from the Actions tab through **Run workflow**. It uses the GitHub-hosted `macos-15` image with Xcode 26.3 to compile a debug build for the iOS simulator and an unsigned macOS release. Physical-device testing and distribution signing are separate. [Apple workflow](../.github/workflows/apple-sdk.yml) · [Hosted runner SDK inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)

Select **Launch Easy on an iPhone simulator and capture first-run setup** to also install and open the built app on a disposable iPhone simulator. The smoke check verifies the app's private SQLite store, its first revision and document checksums, and that setup is pending with an empty workspace. The run saves a first-launch screenshot as `easy-iphone-setup` for seven days. [Simulator smoke script](../tool/benchmark/ios_simulator_smoke.py)

Both workflows request read-only repository contents and use GitHub's checkout action at its exact release commit. Builds stay in the runner workspace. Flutter comes directly from its upstream repository. [Checkout v6.0.2](https://github.com/actions/checkout/releases/tag/v6.0.2) · [Flutter 3.50.1](https://github.com/flutter/flutter/releases/tag/3.50.1)

Run the Linux checks from a clone with the build packages in the README.

```sh
flutter pub get --enforce-lockfile
git diff --exit-code -- pubspec.lock
flutter analyze --no-pub
python3 -m unittest discover -s test -p 'test_*.py'
TZ=Europe/London flutter test --no-pub --concurrency=2
TZ=America/New_York flutter test --no-pub --concurrency=2 \
  test/capture_text_test.dart test/calendar_page_test.dart \
  test/calendar_record_editor_test.dart test/workspace_calendar_persistence_test.dart \
  test/review_test.dart
TZ=Australia/Lord_Howe flutter test --no-pub --concurrency=2 \
  test/capture_text_test.dart test/calendar_page_test.dart
flutter build linux --release --no-pub
```
