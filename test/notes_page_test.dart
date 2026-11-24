import 'package:easy/list_pages.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _longNote = NoteItem(
  id: 'multilingual',
  title: 'ملاحظات العمل 日本語の計画 résumé é 👩🏽‍💻 and a long title',
  body: '\nZebra preview with العربية and 日本語\u2028Second line',
  updated: DateTime(2026, 11, 23),
  pinned: true,
  folder: List.filled(9, 'Folder with a long name').join(' '),
);

final _emptyNote = NoteItem(
  id: 'empty',
  title: ' ',
  body: '\n\n ',
  updated: DateTime(2026, 11, 22),
);

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('notes are stacked compactly at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final newer = NoteItem(
        id: 'newer',
        title: 'Railway notes',
        body: 'Make a short list of connections.\nSecond line: York.',
        updated: DateTime(2026, 11, 24),
      );
      final older = NoteItem(
        id: 'older',
        title: 'Reading list',
        body: 'Pick up a book after work.',
        updated: DateTime(2026, 11, 22),
      );
      NoteItem? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Scaffold(
            body: NotesPage(
              notes: [older, newer],
              onNoteTap: (note) => opened = note,
            ),
          ),
        ),
      );

      final first = find.byKey(const ValueKey('newer'));
      final second = find.byKey(const ValueKey('older'));
      final firstRect = tester.getRect(first);
      final secondRect = tester.getRect(second);
      expect(firstRect.left, secondRect.left);
      expect(firstRect.width, secondRect.width);
      expect(firstRect.height, inInclusiveRange(48, 72));
      expect(firstRect.bottom, lessThan(secondRect.top));

      final preview = find.descendant(
        of: first,
        matching: find.text('Make a short list of connections.'),
      );
      final text = tester.widget<Text>(preview);
      expect(text.maxLines, 1);
      expect(
        find.descendant(of: first, matching: find.text('Nov 24, 2026')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Search notes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'York');
      await tester.pumpAndSettle();
      expect(find.text('Reading list'), findsNothing);
      await tester.tap(find.text('Railway notes'));
      expect(opened, same(newer));
    });
  }

  for (final size in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(820, 1180),
    const Size(1440, 900),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('notes keep title, preview and date at ${size.width} × '
          '${size.height}, ${scale}x text', (tester) async {
        await _showNotes(tester, size: size, scale: scale);
        final heading = tester.renderObject<RenderParagraph>(
          find.text('Notes'),
        );
        expect(
          heading.size.height,
          lessThan(heading.text.style!.fontSize! * scale * 1.3),
        );

        final row = find.byKey(const ValueKey('multilingual'));
        final text = find.descendant(of: row, matching: find.byType(RichText));
        final paragraphs = tester.renderObjectList<RenderParagraph>(text);
        final preview = paragraphs.singleWhere(
          (paragraph) => paragraph.text.toPlainText().contains('Zebra preview'),
        );
        final sample = preview.text.toPlainText();
        final start = sample.indexOf('Zebra');
        expect(
          preview.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 1),
          ),
          isNotEmpty,
        );
        expect(sample, isNot(contains('Second line')));
        expect(preview.maxLines, 1);
        expect(
          paragraphs.map((paragraph) => paragraph.text.toPlainText()).join(' '),
          contains('Nov 23, 2026'),
        );
        expect(tester.widget<Text>(find.text(_longNote.title)).maxLines, 1);

        final untitled = find.text('Untitled note');
        await tester.ensureVisible(untitled);
          await tester.pumpAndSettle();
        expect(untitled.hitTestable(), findsOneWidget);
        final blank = find.byKey(const ValueKey('empty'));
        final blankDetails = find.descendant(
          of: blank,
          matching: find.text('Nov 22, 2026'),
        );
        expect(blankDetails, findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Escape closes note search and restores keyboard navigation', (
    tester,
  ) async {
    NoteItem? opened;
    await _showNotes(
      tester,
      size: const Size(320, 568),
      scale: 2,
      onOpen: (note) => opened = note,
    );
    for (var index = 0; index < 2; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    await tester.enterText(field, '日本語');
    await tester.pumpAndSettle();
    expect(find.text('Untitled note'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened, same(_longNote));
  });
}

Future<void> _showNotes(
  WidgetTester tester, {
  required Size size,
  required double scale,
  ValueChanged<NoteItem>? onOpen,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: Scaffold(
        body: NotesPage(
          notes: [_longNote, _emptyNote],
          onNoteTap: onOpen ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
