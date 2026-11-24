# Easy

Easy brings your calendar, tasks, notes, and activity into one device-first workspace. It opens with example entries you can edit while you try the views.

- **Today** shows a note to self, upcoming events, and tasks due today. A focus mode can bring forward a workout, meal log, or a different group of tasks.
- **Calendar** puts the schedule below a tappable date. On a phone, swipe sideways for the next day or scroll vertically through days. Wide windows show a week.
- **Tasks and notes** use lightweight lists and a contextual detail pane on wider screens. Tasks support nesting, effort and prerequisite fields. Notes support folders, tags, pins, Markdown preview and links to workspace records.
- **Navigation** starts at the bottom-left button on a phone. Hold, drag toward a destination and release, or tap and choose a destination. The plus opens a single capture field. Hold it to record. Slide up to lock recording or left to cancel.
- **Capture** stays available in every focus mode. A voice recording is saved as a draft. Review its transcript, category and proposed items before applying them.
- **Gym** keeps the next exercise and its settings in reach. Plan a workout once, on weekdays or on an interval. Edit individual metrics and sets, skip an exercise, and review previous sessions.
- **Settings** controls optional features, calendar visibility, focus modes, backups, and AI. Disabling a feature keeps its records in the workspace.

## Run

Use Flutter 3.50.1 with the checked-in dependency lockfile.

```sh
flutter pub get --enforce-lockfile
flutter run -d linux
```

On Debian-based Linux, the build uses Clang, CMake, Ninja, GTK 3, GStreamer and libsecret development packages. Audio playback uses GStreamer plugins. The microphone adapter uses PulseAudio-compatible tools and FFmpeg.

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libsecret-1-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good pulseaudio-utils ffmpeg
```

Run the checks from the repository root.

```sh
flutter analyze
TZ=Europe/London flutter test
flutter build linux
```

## AI and backups

The app starts with offline capture. Optional local inference uses an explicitly configured loopback provider. Paid inference uses an explicitly configured HTTPS endpoint and a GBP ledger that reserves the configured maximum before a request. You can choose which fields to include and separately opt into automatic duration suggestions. The system credential service holds API keys on native platforms.

Logical backups preserve workspace records, including local calendar series and the metadata of recordings and photos. Media files are stored separately by content hash. Native version history supports previewing a full restore or selecting records to restore. Restoring a workspace retains the separate device AI spend ledger.

## Change the name

Override the in-app name when running or building.

```sh
flutter run -d linux --dart-define=APP_NAME='My Workspace'
```

Use the display-name tool to update the default in-app name and the platform labels in a local checkout. It preserves the identifiers that tie an installed app to its data.

```sh
python3 tool/set_display_name.py --dry-run 'My Workspace'
python3 tool/set_display_name.py 'My Workspace'
```

[Display-name tool](tool/set_display_name.py)

## Verification

This repository is a development build. Linux has native release and offline journey evidence. Android has offline release AOT evidence for ARMv7, ARM64, and x86-64. Apple Calendar code has fake-channel and static Swift checks. See the release evidence for the checks that still need native devices. [Test evidence](docs/TEST_EVIDENCE.md) · [Acceptance status](docs/ACCEPTANCE.md)
