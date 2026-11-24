# Continuous integration

**Verification** runs on pull requests and pushes to `main`. It checks out the requested revision, verifies Flutter 3.50.1 against its upstream commit, and restores packages from the checked-in `pubspec.lock`. The Linux runner analyzes Dart, runs the native source checks and full Flutter suite, checks daylight-saving transitions in New York and Lord Howe, and compiles the Linux release. [Verification workflow](../.github/workflows/verification.yml) · [SDK bootstrap](../.github/scripts/bootstrap-flutter.sh)

An active `main` run can finish while the newest push waits. Each new pull request revision cancels the previous run for that pull request.

**Apple SDK check** is available from the Actions tab through **Run workflow**. It uses the GitHub-hosted `macos-15` image with Xcode 26.3 to compile a debug build for the iOS simulator and an unsigned macOS release. Physical-device testing and distribution signing are separate. [Apple workflow](../.github/workflows/apple-sdk.yml) · [Hosted runner SDK inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)

Select **Launch the macOS release and verify its private first-run workspace** to run the built desktop app. The check signs a runner-local copy ad hoc with the app's existing release entitlements, starts the app in its own fresh sandbox container, and verifies the private SQLite workspace while the app is running. [macOS smoke script](../tool/benchmark/macos_release_smoke.py)

Select **Launch Easy on an iPhone simulator and capture first-run setup** to also install and open the built app on a disposable iPhone simulator. This option runs on `macos-26` with Xcode 26.4.1, which includes Apple's fix for a simulator disk-image service hang. The smoke check verifies the app's private SQLite store, its first revision and document checksums, and that setup is pending with an empty workspace. The run saves a first-launch screenshot as `easy-iphone-setup` for seven days. [Simulator smoke script](../tool/benchmark/ios_simulator_smoke.py) · [Runner SDK inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) · [Xcode release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_4-release-notes)

**Android emulator smoke** is a separate manual workflow on GitHub’s Ubuntu 24.04 x64 runner. It validates KVM, builds and checks a development-signed, non-debuggable release APK, and launches it on a disposable Android 36 AOSP emulator. The emulator’s root shell reads copies of the app’s private SQLite database and write-ahead log for the same empty setup verification. The workflow saves `easy-android-setup` for seven days. [Android workflow](../.github/workflows/android-smoke.yml) · [Hardware acceleration](https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available/) · [Android smoke script](../tool/benchmark/android_emulator_smoke.py)

Select **Replay a synthetic saved meal photo through two cold starts** to exercise the image picker's saved-result recovery on that emulator after first-launch setup. The check uses a generated 3 × 2 PNG and verifies one local meal draft, the resized attachment checksum, and an unchanged revision on duplicate replay. [Meal recovery script](../tool/benchmark/android_meal_recovery_smoke.py)

Select **Review the sample workspace with Android touch input and a saved event** to exercise the bottom-corner controls and the Calendar day swipe. The run keeps six PNG checkpoints and the JSON result for seven days. [Touch review script](../tool/benchmark/android_touch_review.py)

The workflows request read-only repository contents and use GitHub's checkout action at its exact release commit. The Linux verification job on `main` retains an extracted-and-checked review archive and its SHA-256 checksum for 14 days. Flutter comes directly from its upstream repository. [Checkout v6.0.2](https://github.com/actions/checkout/releases/tag/v6.0.2) · [Flutter 3.50.1](https://github.com/flutter/flutter/releases/tag/3.50.1)

| Hosted check | Revision | Result |
| --- | --- | --- |
| Linux | `477594a` | Analyzer, eight Python checks, 886 Flutter tests with seven conditional skips, both DST checks, release compilation and archive extraction passed. [Run](https://github.com/launchsites/easy/actions/runs/45363213755) |
| Apple SDK | `f8c14fc` | The iOS simulator debug build and unsigned macOS release compiled with Xcode 26.3. [Run](https://github.com/launchsites/easy/actions/runs/45334132108) |
| iPhone simulator | `b20417a` | Xcode 26.4.1 compiled iOS and macOS. The iPhone 17 simulator on iOS 26.4 launched Easy, verified the private empty workspace, and captured the 1206 × 2622 setup screen. [Run](https://github.com/launchsites/easy/actions/runs/45341653863) |
| macOS startup | `3f56109` | Easy's ARM64 release launched on macOS 15.8.2 with Xcode 26.3. A runner-local ad hoc copy passed strict signature and release-entitlement checks. The live app created its sandboxed workspace, where a read-only probe verified the empty pending setup, SQLite integrity, and document checksums. [Run](https://github.com/launchsites/easy/actions/runs/45345576521) |
| Android emulator | `93bdea7` | The non-debuggable x86-64 release launched on AOSP API 36, verified the private workspace, and captured the 1080 × 2400 setup screen. [Run](https://github.com/launchsites/easy/actions/runs/45337863946) |
| Android setup and meal replay | `975c6e8` | AOSP API 36 verified first launch, 17.27:1 clock and 3.01:1 navigation glyph contrast, one recovered draft at revision 3, and unchanged workspace revision and attachment checksum after replay. [Run](https://github.com/launchsites/easy/actions/runs/45343142083) |
| Android simplified system theme | `5c4bd85` | The AOSP API 36 first-launch check passed and the photographed clock and navigation glyph contrast matched the previous run. [Run](https://github.com/launchsites/easy/actions/runs/45344251920) |
| Android touch journey | `3832097` | The Android 36 release completed sample setup, selected Calendar with a held drag, swiped to the next day, and saved a timed event using the two floating controls. [Run](https://github.com/launchsites/easy/actions/runs/45347390357) |

## Review builds

The downloadable previews were built from `477594a` and include SHA-256 checksums. GitHub sign-in is required. Unzip the Linux download, extract `easy-linux-x64.tar.gz`, and run `./easy` from the inner `easy` directory. The Android archives contain development-signed APKs.

- [Linux x86-64](https://github.com/launchsites/easy/actions/runs/45363213755/artifacts/14906820186)
- [Android ARM64](https://github.com/launchsites/easy/actions/runs/45363351696/artifacts/14906785512)
- [Android ARMv7](https://github.com/launchsites/easy/actions/runs/45363351696/artifacts/14906246598)
- [Android x86-64](https://github.com/launchsites/easy/actions/runs/45363351696/artifacts/14906331419)

## Run the checks locally

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
