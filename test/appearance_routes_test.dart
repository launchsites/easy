import 'dart:math' as math;

import 'package:easy/appearance/appearance.dart';
import 'package:easy/calendar_page.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/today_page.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final profile in AppearanceProfile.values) {
    testWidgets('${profile.name} calendar keeps imported event text readable', (
      tester,
    ) async {
      final theme = previewEasyTheme(profile);
      final dark = theme.brightness == Brightness.dark;
      _viewport(tester, dark ? const Size(1110, 820) : const Size(390, 844));
      final date = DateTime(2026, 4, 7);
      final event = _event(date, dark ? Colors.black : Colors.white);
      CalendarEvent? opened;
      await _show(
        tester,
        theme,
        CalendarPage(
          date: date,
          events: [event],
          onDateChanged: (_) {},
          onEventTap: (value) => opened = value,
        ),
      );

      final heading = find.byKey(const ValueKey('calendar-date'));
      final headingText = find.descendant(
        of: heading,
        matching: find.byType(Text),
      );
      expect(_textColor(tester, headingText), theme.colorScheme.onSurface);
      final title = find.text(event.title).hitTestable();
      expect(title, findsOneWidget);
      expect(
        _contrast(_textColor(tester, title), _materialColor(tester, title)),
        greaterThanOrEqualTo(4.5),
      );
      await tester.tap(title);
      expect(opened, same(event));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop Today applies the full-dark schedule and task colors', (
    tester,
  ) async {
    _viewport(tester, const Size(1110, 820));
    final theme = previewEasyTheme(AppearanceProfile.fullDark);
    final date = DateTime(2026, 4, 7);
    final event = _event(date, Colors.black);
    await _show(
      tester,
      theme,
      TodayPage(
        date: date,
        events: [event],
        tasks: [_task(date)],
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
    );

    final schedule = find.text('Schedule');
    expect(_textColor(tester, schedule), theme.colorScheme.onSurface);
    final place = find.text(event.location!);
    expect(
      _contrast(_textColor(tester, place), _materialColor(tester, place)),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _textColor(tester, find.text('Pack charger')),
      theme.colorScheme.onSurfaceVariant,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone Today uses the full-dark note surface and readable rows', (
    tester,
  ) async {
    _viewport(tester, const Size(320, 568));
    final theme = previewEasyTheme(AppearanceProfile.fullDark);
    final date = DateTime(2026, 4, 7);
    final event = _event(date, Colors.black);
    var openedNote = false;
    await _show(
      tester,
      theme,
      MobileHome(
        date: date,
        mode: null,
        modeControl: const Text('Mode'),
        note: NoteItem(
          id: 'note',
          title: 'Note to self',
          body: 'Bring the adapter.',
          updated: date,
        ),
        events: [event],
        tasks: [_task(date)],
        onNoteTap: () => openedNote = true,
        onCalendarTap: () {},
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
    );
    final note = find.text('Bring the adapter.');
    expect(_materialColor(tester, note), theme.colorScheme.surfaceContainerLow);
    expect(_textColor(tester, note), theme.colorScheme.onSurfaceVariant);
    expect(
      _textColor(tester, find.text(event.title)),
      theme.colorScheme.onSurface,
    );
    await tester.tap(note);
    expect(openedNote, isTrue);
    expect(tester.takeException(), isNull);
  });
}

CalendarEvent _event(DateTime date, Color color) => CalendarEvent(
  id: 'imported-event',
  title: 'Check delivery',
  start: date.add(const Duration(hours: 9)),
  end: date.add(const Duration(hours: 10, minutes: 15)),
  category: 'work',
  sourceLabel: 'Imported calendar',
  location: 'Parcel room',
  color: color,
);

TaskItem _task(DateTime date) => TaskItem(
  id: 'task',
  title: 'Pack charger',
  category: 'work',
  date: date,
  done: true,
);

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _show(WidgetTester tester, ThemeData theme, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: page),
    ),
  );
  await tester.pumpAndSettle();
}

Color _textColor(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style!.color!;

Color _materialColor(WidgetTester tester, Finder text) =>
    tester.element(text).findAncestorWidgetOfExactType<Material>()!.color!;

double _contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}
