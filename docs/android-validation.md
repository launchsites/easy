# Android release verification

Android release assembly and lint passed in 5 minutes 34 seconds from a fresh archive of `5c4bd854f21d864a7eb352b29acfb95358c8e8f8`. Dependency resolution used verified local caches. The toolchain used Android SDK 36, Build Tools 36.0.0, NDK 28.2.13676358, JDK 21, Gradle 9.5.0, and Android Gradle Plugin 9.3.1. [Package verification](benchmark-results/android-release-5c4bd85-20261124.json)

| ABI | Package bytes | SHA-256 |
| --- | ---: | --- |
| `arm64-v8a` | 26,797,725 | `f208a1adeb6b9fa2ff77b74fbb2e591578a53e19e9de6e6b5e7d3edf34b8c4ca` |
| `armeabi-v7a` | 25,128,119 | `18f1d39ab7b153e4373ddd17e6bacbc97ac23311798e74d8a7cf6cc3fdbc7e1d` |
| `x86_64` | 28,199,894 | `521d9d81f1d5940d6783c019c90839c5eb1ef5b48f6d5a1a13b951aaf608e07e` |

Each package passed Android signature and 16 KiB ZIP alignment checks. All 15 native libraries matched their APK's ABI and 16 KiB load alignment. The compiled manifest declared a non-debuggable app, minimum SDK 24, target SDK 36, and `app.launchsites.easy.MainActivity` as the launcher. Its compiled network policy permits cleartext only on exact IPv4 and IPv6 loopback addresses. Its backup settings disable older Android backup and exclude workspace domains from Android 12 and later cloud backup and device transfer.

Release lint reported no issues. Gradle emitted a separate deprecation summary. The packages use a development signing certificate. These three APKs were checked at package level.

The hosted AOSP API 36 emulator built its own development-signed x86-64 release from `5c4bd854f21d864a7eb352b29acfb95358c8e8f8`, installed it, and verified an empty private SQLite workspace with setup pending. The run captured the first-launch screen. Physical-device interaction, notification delivery, and Android's enforcement of the compiled policies still require runtime coverage. [Hosted emulator run](https://github.com/launchsites/easy/actions/runs/45344251920)

The hosted release at `975c6e8bd4653cad18d8d7dd3ca1d5363672ba62` completed Full setup at revision 2. A synthetic result in the Android image picker's own cache recovered as one local meal draft in revision 3. The managed 3×2 image matched the platform's resized fixture bytes. Replaying the same cached result after another cold launch kept the same revision and workspace digest. The scenario used a disposable emulator with synthetic image-picker state. [Hosted photo recovery run](https://github.com/launchsites/easy/actions/runs/45343142083)


A separate AOSP API 36 release completed Full sample setup at 1080 × 2400. A continuous held drag from the bottom-left button selected Calendar. A horizontal touch swipe advanced the day. The bottom-right capture button and touch submit saved one timed event on the new day, moving the private workspace from revision 2 to 3. The other sample records retained their contents, and SQLite passed its integrity check. [Hosted touch run](https://github.com/launchsites/easy/actions/runs/45347390357) · [Verification results](benchmark-results/android-touch-3832097-20261124.json)

The hosted `a339bf8` release produced all three development-signed review APKs. Each package passed signature, manifest, compiled policy, and 16 KiB ZIP and ELF alignment checks. Release lint reported zero errors and one notice about a newer available Gradle version. A second runner verified the exact uploaded archives and their internal checksums, then installed the uploaded x86-64 APK on AOSP 36. That APK completed setup, chose Calendar with the held drag, swiped forward one day, and saved the reviewed 10:05–10:25 event with touch input. [Hosted packages](https://github.com/launchsites/easy/actions/runs/45348743492) · [Hosted APK readback and runtime](https://github.com/launchsites/easy/actions/runs/45350059663) · [Verification results](benchmark-results/android-packages-a339bf8-hosted-20261124.json)


The downloadable `ecdc55a` packages also passed assembly, signature and compiled policy checks, and 16 KiB ZIP and ELF alignment on each ABI. Release lint recorded zero errors and one available Gradle upgrade warning. The independent AOSP runtime check installed the exact uploaded x86-64 APK verified against its digest, completing setup and the held-drag, day swipe, and timed event save. [Current review APKs](https://github.com/launchsites/easy/actions/runs/45352804011) · [Uploaded APK runtime](https://github.com/launchsites/easy/actions/runs/45353884908) · [Current package evidence](benchmark-results/android-packages-ecdc55a-hosted-20261124.json)


The `477594a` review build includes the compact mobile Calendar clock labels. The three ABI packages passed signature, compiled-policy and 16 KiB alignment checks. Release lint recorded zero errors and one available Gradle upgrade warning. A separate AOSP 36 host verified the original uploaded x86-64 APK, completed Full sample setup, opened Calendar with the held drag, swiped to the following day and saved one event with touch input. [Current review APKs](https://github.com/launchsites/easy/actions/runs/45363351696) · [Current uploaded APK runtime](https://github.com/launchsites/easy/actions/runs/45364549136) · [Verification results](benchmark-results/android-packages-477594a-hosted-20261124.json) · [Current Calendar screenshot](runtime-previews/477594a/README.md)

```sh
flutter build apk --release --split-per-abi
cd android
./gradlew :app:lintRelease
```

The defensive source checks can also run without the SDK.

```sh
python3 test/test_android_manifest_privacy.py
```
