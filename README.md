# Easy

Easy is a local workspace for your calendar, tasks, and notes. It opens with sample entries so you can try the views and interactions right away. New entries and edits are saved on the device.

- **Today** opens on the date, upcoming events, and tasks due today. On a phone it also includes a note to self. Pick a mode to focus the page. Gym brings the next workout and its note to the top.
- **Calendar** puts the schedule below a single tappable date. On a phone, swipe sideways to jump a day or scroll through days vertically. Wide windows show the week together.
- **Tasks** groups open and completed work by date. **Notes** is a searchable list with a title, preview, and date on each row.
- **Mobile navigation** opens from the bottom-left button. Hold, drag toward a destination, and release to switch views. Return to the center before releasing to cancel. You can also tap to open the menu, then tap a destination. The bottom-right plus opens a single capture field.
- **Quick capture** takes an event like `Studio review tomorrow 14:00-14:45` in one line. When a time is missing, the same field asks for it. Tasks default to today and accept a typed due date. Notes accept plain text.
- **Gym** shows the next workout in a red-framed mode. Plan a workout once, on selected weekdays, or every few days. In a session, tap a treadmill metric or a set’s weight or reps to edit it, then mark it done or skipped. You can add and remove exercises or sets, and start freestyle.

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
