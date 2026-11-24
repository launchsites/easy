# Easy

Easy brings your calendar, tasks, notes, and activity into one device-first workspace. Start with a blank workspace or try sample data. Minimal, Planner, and Full presets let you choose which features to see. [Appearance previews](docs/DESIGN_PREVIEWS.md)

- **Today** shows a note to self, upcoming events, and tasks due today. A focus mode can bring forward a workout, meal log, or a different group of tasks.
- **Planning** uses your saved hours, calendar commitments, prerequisites, and task estimates. Today can flag a task that fits a verified free window. Open What fits now to see alternatives or plan the day. Calendar time blocks are saved after you review them.
- **Calendar** puts the schedule below a tappable date. On a phone, swipe sideways for the next day or scroll vertically through days. Wide windows show a week.
- **Tasks and notes** use lightweight lists and a contextual detail pane on wider screens. Tasks support nesting, effort and prerequisite fields. Notes support folders, tags, pins, Markdown preview and links to workspace records.
- **Navigation** starts at the bottom-left button on a phone. Hold, drag toward a destination and release, or tap and choose a destination. The plus opens a single capture field. Hold it to record. Slide up to lock recording or left to cancel.
- **Capture** stays available in every focus mode. A voice recording is saved as a draft. Review its transcript, category and proposed items before applying them.
- **Gym** keeps the next exercise and its settings in reach. Plan a workout once, on weekdays or on an interval. Edit actual sets and metrics while keeping the planned values, or review a spoken result from the live session.
- **Settings** controls optional features, calendar visibility, focus modes, follow-up rules, backups, and AI. Disabling a feature keeps its records in the workspace.

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

Easy starts with offline capture. Connect a local loopback model or configure an HTTPS API with your own key and a monthly limit in GBP. Optional foreground estimates can adjust their pace to the remaining budget. Review which fields and images a provider will receive and confirm the suggestions you want to use. [Local model setup](docs/local-ai-setup.md) · [Privacy and threat model](docs/privacy-and-threat-model.md)

Use native version history to review a full restore or recover selected records. Encrypted backups can include original recordings and photos. The device keeps AI spend in a separate ledger across restores. Pair devices to review and exchange selected records through encrypted files. [Recovery validation](docs/storage-validation.md) · [Manual sync](docs/manual-sync.md)

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

This repository is a development build. Linux has native release, offline, restart, and performance evidence. Android review APKs were built and inspected for ARMv7, ARM64, and x86-64. Hosted Apple SDK builds passed for the iOS simulator and macOS. Physical phone tests, real EventKit account interoperability, and live paid billing verification remain open. [Test evidence](docs/TEST_EVIDENCE.md) · [Acceptance status](docs/ACCEPTANCE.md)
