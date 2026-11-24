import 'package:easy/list_pages.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.textSpan?.toPlainText().contains('Make a short list') ==
                  true,
        ),
      );
      final text = tester.widget<Text>(preview);
      expect(text.maxLines, 1);
      expect(text.textSpan!.toPlainText(), contains('Nov 24, 2026'));
      expect(text.textSpan!.toPlainText(), isNot(contains('Second line')));

      await tester.tap(find.byTooltip('Search notes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'York');
      await tester.pumpAndSettle();
      expect(find.text('Reading list'), findsNothing);
      await tester.tap(find.text('Railway notes'));
      expect(opened, same(newer));
    });
  }
}
