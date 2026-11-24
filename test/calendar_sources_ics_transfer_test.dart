import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _transferText =
    'BEGIN:VCALENDAR\r\n'
    'VERSION:2.0\r\n'
    'X-WR-CALNAME:Sample calendar\r\n'
    'BEGIN:VTIMEZONE\r\n'
    'TZID:Europe/London\r\n'
    'BEGIN:STANDARD\r\n'
    'DTSTART:20261025T020000\r\n'
    'TZOFFSETFROM:+0100\r\n'
    'TZOFFSETTO:+0000\r\n'
    'END:STANDARD\r\n'
    'END:VTIMEZONE\r\n'
    'BEGIN:VEVENT\r\n'
    'UID:repeat\r\n'
    'DTSTART:20261124T090000Z\r\n'
    'DTEND:20261124T100000Z\r\n'
    'RRULE:FREQ=WEEKLY;COUNT=3\r\n'
    'SUMMARY:Team meeting\r\n'
    'END:VEVENT\r\n'
    'BEGIN:VEVENT\r\n'
    'UID:repeat\r\n'
    'RECURRENCE-ID:20261201T090000Z\r\n'
    'DTSTART:20261202T090000Z\r\n'
    'SUMMARY:Moved meeting\r\n'
    'END:VEVENT\r\n'
    'BEGIN:VEVENT\r\n'
    'UID:duplicate\r\n'
    'DTSTART:20261124T110000Z\r\n'
    'SUMMARY:Duplicate one\r\n'
    'END:VEVENT\r\n'
    'BEGIN:VEVENT\r\n'
    'UID:duplicate\r\n'
    'DTSTART:20261124T130000Z\r\n'
    'SUMMARY:Duplicate two\r\n'
    'END:VEVENT\r\n'
    'END:VCALENDAR\r\n';

final _date = DateTime(2026, 11, 24);
final _chooseFile = find.widgetWithText(FilledButton, 'Choose .ics file');
final _importSelected = find.widgetWithText(FilledButton, 'Import selected');

void main() {
  testWidgets(
    'import is explicit and selected documents keep series metadata and duplicate identity',
    (tester) async {
      var picks = 0;
      final imports = <IcsTransferSelection>[];
      await _open(
        tester,
        pick: () async {
          picks++;
          return _transferText;
        },
        apply: (result) async => imports.add(result),
      );
      expect(picks, 0);
      expect(tester.widget<FilledButton>(_importSelected).onPressed, isNull);

      await tester.tap(_chooseFile);
      await _waitFor(tester, find.text('Sample calendar'));
      expect(picks, 1);
      expect(imports, isEmpty);
      expect(
        find.widgetWithText(CheckboxListTile, 'Team meeting'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(CheckboxListTile, 'Moved meeting'),
        findsNothing,
      );
      expect(find.textContaining('Duplicate source UID'), findsNWidgets(2));
      expect(find.textContaining('3 occurrences'), findsOneWidget);

      await tester.tap(find.widgetWithText(CheckboxListTile, 'Duplicate one'));
      await tester.pump();
      expect(imports, isEmpty);
      await tester.tap(_importSelected);
      await _waitFor(tester, find.text('Calendar imported.'));
      final selected = imports.single;
      expect(selected.selectedSourceIndexes, {0, 1, 3});
      expect(selected.originalCalendar.events, hasLength(4));
      expect(selected.calendar.events.map((event) => event.uid), [
        'repeat',
        'repeat',
        'duplicate',
      ]);
      expect(
        selected.calendar.events.first.recurrenceRule,
        'FREQ=WEEKLY;COUNT=3',
      );
      expect(selected.calendar.events[1].recurrenceId, isNotNull);
      expect(selected.calendar.encode(), contains('BEGIN:VTIMEZONE\r\n'));
      final duplicate = selected.previewItems.singleWhere(
        (item) => item.sourceUid == 'duplicate',
      );
      expect(duplicate.occurrence.sourceIndex, 2);
      expect(duplicate.localId, endsWith('/2'));
      expect(tester.widget<FilledButton>(_importSelected).onPressed, isNull);
    },
  );

  testWidgets('parse and expansion errors prevent import', (tester) async {
    var picks = 0;
    var applied = false;
    await _open(
      tester,
      pick: () async {
        picks++;
        return switch (picks) {
          1 => _transferText.replaceFirst(
            'DTSTART:20261124T090000Z',
            'DTSTART:20260230T090000Z',
          ),
          2 => _transferText.replaceFirst('FREQ=WEEKLY', 'FREQ=HOURLY'),
          _ => _transferText.replaceFirst(
            'VERSION:2.0',
            'VERSION:2.0\r\nMETHOD:CANCEL',
          ),
        };
      },
      apply: (_) async => applied = true,
    );

    await tester.tap(_chooseFile);
    await _waitFor(
      tester,
      find.textContaining('Invalid iCalendar date or time'),
    );
    expect(tester.widget<FilledButton>(_importSelected).onPressed, isNull);
    expect(find.byType(CheckboxListTile), findsNothing);

    await tester.tap(_chooseFile);
    await _waitFor(
      tester,
      find.textContaining('Unsupported recurrence frequency HOURLY'),
    );
    expect(tester.widget<FilledButton>(_importSelected).onPressed, isNull);

    await tester.tap(_chooseFile);
    await _waitFor(
      tester,
      find.textContaining('This file contains cancellation notices.'),
    );
    expect(tester.widget<FilledButton>(_importSelected).onPressed, isNull);
    expect(applied, isFalse);
  });

  testWidgets('export sends source rules and original UIDs to the file saver', (
    tester,
  ) async {
    var picks = 0;
    String? filename;
    String? content;
    await _open(
      tester,
      pick: () async {
        picks++;
        return null;
      },
      exportCalendar: IcsCalendar.parse(_transferText),
      save: (name, contents) async {
        filename = name;
        content = contents;
        return true;
      },
    );
    expect(content, isNull);
    await tester.tap(find.text('Export calendar'));
    await _waitFor(tester, find.text('Calendar exported.'));
    expect(picks, 0);
    expect(filename, 'Easy Calendar.ics');
    final exported = IcsCalendar.parse(content!);
    expect(exported.events.map((record) => record.uid), [
      'repeat',
      'repeat',
      'duplicate',
      'duplicate',
    ]);
    expect(exported.events.first.recurrenceRule, 'FREQ=WEEKLY;COUNT=3');
    expect(exported.events[1].recurrenceId, isNotNull);
    expect(content, contains('BEGIN:VTIMEZONE\r\n'));
  });

  testWidgets(
    'a canceled pick leaves the preview intact and empty selection disables import',
    (tester) async {
      var picks = 0;
      await _open(
        tester,
        pick: () async {
          picks++;
          return picks == 1 ? _transferText : null;
        },
      );
      await tester.tap(_chooseFile);
      await _waitFor(tester, find.text('Sample calendar'));
      await tester.tap(_chooseFile);
      await tester.pumpAndSettle();
      expect(find.text('Sample calendar'), findsOneWidget);
      for (final title in ['Team meeting', 'Duplicate one', 'Duplicate two']) {
        await tester.tap(find.widgetWithText(CheckboxListTile, title));
        await tester.pump();
      }
      expect(tester.widget<FilledButton>(_importSelected).onPressed, isNull);
    },
  );

  testWidgets(
    'older source records remain selectable beyond the bounded preview',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source =
          'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n'
          'UID:older\r\nDTSTART:20200101T090000Z\r\nSUMMARY:Older appointment\r\n'
          'END:VEVENT\r\nEND:VCALENDAR\r\n';
      final imports = <IcsTransferSelection>[];
      await _open(
        tester,
        pick: () async => source,
        apply: (result) async => imports.add(result),
        textScale: 2,
      );
      await tester.tap(_chooseFile);
      await _waitFor(tester, find.text('Calendar preview'));
      await tester.scrollUntilVisible(find.text('Older appointment'), 80);
      expect(find.text('Outside preview dates'), findsOneWidget);
      expect(tester.widget<FilledButton>(_importSelected).onPressed, isNotNull);
      await tester.tap(_importSelected);
      await _waitFor(tester, find.text('Calendar imported.'));
      expect(imports.single.calendar.events.single.uid, 'older');
      expect(imports.single.previewItems, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _open(
  WidgetTester tester, {
  required Future<String?> Function() pick,
  Future<void> Function(IcsTransferSelection)? apply,
  Future<bool> Function(String, String)? save,
  IcsCalendar? exportCalendar,
  double textScale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: IcsTransferPage(
      pickFile: pick,
      onApply: apply ?? (_) async {},
      saveFile: save ?? (_, _) async => false,
      initialDate: _date,
      exportCalendar: exportCalendar,
    ),
  ),
);

Future<void> _waitFor(WidgetTester tester, Finder result) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (result.evaluate().isNotEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(result, findsOneWidget);
  expect(find.byType(LinearProgressIndicator), findsNothing);
}
