# Easy

Easy is a local workspace for your calendar, tasks, and notes. It opens with sample entries so you can try the views and interactions right away. New entries and edits are saved on the device.

- **Today** shows the selected day’s schedule and tasks.
- **Calendar** offers day, week, and month views, with an agenda, date jumping, and event editing.
- **Tasks** groups open and completed work by date. **Notes** supports search across titles and text.
- **Mobile navigation** opens from the bottom-left button. Hold, drag toward a destination, and release to switch views. Return to the center before releasing to cancel. You can also tap to open the menu, then tap a destination. The bottom-right plus opens the editor.

## Run

Use Flutter 3.50.1 or a compatible newer version. Install the platform prerequisites for your target, then run:

```sh
flutter pub get
flutter run -d linux
```

Use `flutter devices` to list your available targets. For automated checks, run `flutter analyze` and `flutter test`.

## Change the name

The in-app name defaults to Easy. Override it when running or building:

```sh
flutter run -d linux --dart-define=APP_NAME='My Workspace'
```

The default is declared in [lib/main.dart](lib/main.dart). The operating system’s launcher label is set in the Android manifest, Apple runner settings, and Linux runner. The browser’s initial title and install label are in `web/index.html` and `web/manifest.json`. Keep the existing bundle identifiers when changing display labels on an installed app so the platform can retain its data.

## Current scope

This starter stores one workspace on the device. Calendar events are maintained inside Easy. Native calendar accounts, recurrence, and multi-device sync are outside the current build.
