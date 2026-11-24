# Android release verification

Android release assembly and lint passed from a fresh archive of `12730c86ac311e5c473a6810a69cc31ec257f1ff`. Dependency resolution used verified local caches. The toolchain used Android SDK 36, Build Tools 36.0.0, NDK 28.2.13676358, JDK 21, Gradle 9.5.0, and Android Gradle Plugin 9.3.1. [Package verification](benchmark-results/android-release-12730c8-20261124.json)

| ABI | Package bytes | SHA-256 |
| --- | ---: | --- |
| `arm64-v8a` | 26,797,725 | `3b3874f2217bbceb2945df272feb39823c3e8a0058a031f770a053de3f1c0716` |
| `armeabi-v7a` | 25,062,583 | `2681560a9af724e2054c7d483219dac116e9257b188bb5553f337ea13694e32f` |
| `x86_64` | 28,199,894 | `e11cf642906a810d94a19382e4eb1eaf2f934c576baa3dc4bf35a3f2c6439e96` |

Each package passed Android signature and 16 KiB ZIP alignment checks. All 15 native libraries matched their APK's ABI and 16 KiB load alignment. The compiled manifest declared a non-debuggable app, minimum SDK 24, target SDK 36, and `app.launchsites.easy.MainActivity` as the launcher. Its compiled network policy permits cleartext only on exact IPv4 and IPv6 loopback addresses. Its backup settings disable older Android backup and exclude workspace domains from Android 12 and later cloud backup and device transfer.

Release lint reported no issues. Gradle emitted a separate deprecation summary. The packages use a development signing certificate. These three APKs were checked at package level.

Separately, the hosted AOSP API 36 emulator installed and launched the development-signed x86-64 release built from `93bdea7fdfa1e527203718d2323c7b84d4d75728`. The run verified an empty private SQLite workspace with setup pending and captured the first-launch screen. Physical-device interaction, notification delivery, and Android's enforcement of the compiled policies still require runtime coverage. [Hosted emulator run](https://github.com/launchsites/easy/actions/runs/45337863946)

```sh
flutter build apk --release --split-per-abi
cd android
./gradlew :app:lintRelease
```

The defensive source checks can also run without the SDK.

```sh
python3 test/test_android_manifest_privacy.py
```
