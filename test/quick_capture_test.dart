import 'package:easy/calendar_page.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/quick_capture.dart';
import 'package:easy/record_editor.dart' show RecordKind;
import 'package:flutter/rendering.dart' show RenderParagraph;
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

  for (final (size, scale, keyboardInset) in [
    (const Size(320, 568), 1.0, 0.0),
    (const Size(320, 568), 2.0, 260.0),
    (const Size(568, 320), 2.0, 145.0),
  ]) {
    testWidgets(
      'capture type labels fit ${size.width} px at ${scale}x with every action',
      (tester) async {
        final capture = await _setup(
          tester,
          RecordKind.note,
          size: size,
          textScale: scale,
          includeTools: true,
        );
        for (final label in ['Task', 'Event', 'Note']) {
          final finder = find.text(label);
          final text = tester.renderObject<RenderParagraph>(finder);
          expect(
            text.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            ),
            hasLength(1),
            reason: label,
          );
          expect(
            text.getBoxesForSelection(
              TextSelection(
                baseOffset: label.length - 1,
                extentOffset: label.length,
              ),
            ),
            isNotEmpty,
            reason: '$label should remain complete',
          );
          final button = find.widgetWithText(TextButton, label);
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
        }
        for (final label in ['Record voice', 'Open capture review', 'Close']) {
          expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        }

        await tester.tap(find.text('Event'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Coffee tomorrow'), findsOneWidget);
        await tester.tap(find.text('Note'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        const title = 'Studio résumé العربية 日本語 👩🏽‍💻';
        const body = 'One line\nA second line\nAnd a third';
        await tester.enterText(_field, '$title\n$body');
        await tester.pumpAndSettle();
        expect(find.byTooltip('Add note').hitTestable(), findsOneWidget);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        final note = capture.result as NoteItem;
        expect(note.title, title);
        expect(note.body, body);
        expect(tester.takeException(), isNull);
      },
    );
  }
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
  double textScale = 1,
  bool includeTools = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
                    allowVoice: includeTools,
                    allowReview: includeTools,
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
