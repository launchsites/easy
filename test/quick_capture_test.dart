import 'package:easy/calendar_page.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/quick_capture.dart';
import 'package:easy/record_editor.dart' show RecordKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const route = ValueKey('launch capture');
final _field = find.byType(TextFormField).first;

void main() {
  testWidgets('Complete time range can use the contextual date directly', (
    tester,
  ) async {
    final capture = await _setup(tester, RecordKind.event);
    await tester.enterText(_field, 'Coffee 10–11am');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add event'), findsOneWidget);
    expect(find.textContaining('Mon, Nov 23'), findsOneWidget);
    await _submit(tester);
    final result = capture.result as CalendarEvent;
    expect(result.title, 'Coffee');
    expect(result.start, DateTime(2026, 11, 23, 10));
    expect(result.end, DateTime(2026, 11, 23, 11));
  });

  testWidgets('One keyboard field collects only missing event values', (
    tester,
  ) async {
    final capture = await _setup(
      tester,
      RecordKind.event,
      size: const Size(320, 568),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(_field, 'Mobility check');
    await _submit(tester);
    expect(find.text('Mon, Nov 23'), findsOneWidget);
    expect(find.text('Start time'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.enterText(_field, '17:30');
    await _submit(tester);
    expect(find.text('End time'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.enterText(_field, '17:00');
    await _submit(tester);
    expect(
      find.textContaining('End time must be after the start'),
      findsOneWidget,
    );
    expect(capture.result, isNull);
    await tester.enterText(_field, '18:15');
    await _submit(tester);
    final result = capture.result as CalendarEvent;
    expect(result.title, 'Mobility check');
    expect(result.start, DateTime(2026, 11, 23, 17, 30));
    expect(result.end, DateTime(2026, 11, 23, 18, 15));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Note to self preserves multiline text and mode under keyboard shortcut',
    (tester) async {
      final capture = await _setup(
        tester,
        RecordKind.note,
        category: 'gym',
        noteToSelf: true,
      );
      expect(find.text('Note to self'), findsOneWidget);
      await tester.enterText(_field, 'A thought\nKeep the good block.');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final result = capture.result as NoteItem;
      expect(result.title, 'A thought');
      expect(result.body, 'Keep the good block.');
      expect(result.category, 'gym');
      expect(result.noteToSelf, true);
    },
  );
}

class _CaptureResult {
  Object? result;
}

Future<_CaptureResult> _setup(
  WidgetTester tester,
  RecordKind kind, {
  String? category,
  bool noteToSelf = false,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final captured = _CaptureResult();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return TextButton(
              key: route,
              onPressed: () async {
                captured.result = await showModalBottomSheet<Object>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => QuickCapture(
                    date: DateTime(2026, 11, 23),
                    kind: kind,
                    initialCategory: category,
                    noteToSelf: noteToSelf,
                  ),
                );
              },
              child: const Text('Capture'),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(route));
  await tester.pumpAndSettle();
  return captured;
}

Future<void> _submit(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}
