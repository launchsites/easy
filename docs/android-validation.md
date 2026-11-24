# Android release verification

The Android build and lint passed offline at `918b71e`. The scratch toolchain used Android SDK 36, Build Tools 36.0.0, NDK 28.2.13676358, JDK 21, Gradle 9.5.0, and Android Gradle Plugin 9.3.1. Missing artifacts were retrieved from Google Maven, Flutter download storage, and Maven Central. The build used a local cache of checksum-verified artifacts.

| ABI | Package bytes | SHA-256 |
| --- | ---: | --- |
| `arm64-v8a` | 25,880,197 | `7f77041d8ddbbec37322881118714db7f667e09db772332ff0062a3aaa3076a2` |
| `armeabi-v7a` | 24,079,523 | `89f6e9b8d4bdb03046e31c31ae05981ba8808796a45c54cda6a00a5eac5b9e47` |
| `x86_64` | 27,282,366 | `37e1d11c30ecc1781124286cd5be0c364d420d0bf0668c478bb41ceb838ea5b0` |

Each package passed Android signature and 16 KiB ZIP alignment checks. ELF headers matched its ABI for Flutter AOT, the Flutter engine, and SQLite. The binary app manifest identified `app.launchsites.easy.MainActivity` as the launcher and declared target SDK 36. The packaged resource table and compiled XML confirmed cleartext is available for exact IPv4 and IPv6 loopback addresses only. The app disables Android backup and excludes its workspace domains from Android 12 and later cloud backup and device transfer.

Release lint reported zero errors and four warnings. The warnings cover synchronous reminder preference storage, compatibility guidance for pre-Android 12 backup declarations, and two obsolete SDK checks or resource qualifiers. The packages use a development signing certificate. Android device startup and notification delivery remain pending physical-device or emulator verification.

```sh
flutter build apk --release --split-per-abi
cd android
./gradlew :app:lintRelease
```

The defensive source checks can also run without the SDK.

```sh
python3 test/test_android_manifest_privacy.py
```
