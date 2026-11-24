import 'package:easy/calendar_page.dart';
import 'package:easy/record_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final (label, start) in [
    ('a precise UTC event', DateTime.utc(2026, 11, 2, 1, 30, 5, 765, 432)),
    (
      'the second occurrence of a repeated hour',
      DateTime.utc(2026, 11, 1, 6, 30).toLocal(),
    ),
  ]) {
    // The second fixture exercises the daylight-saving fold with TZ=America/New_York.
    testWidgets('editing the title of $label preserves its instants', (
      tester,
    ) async {
      final end = start.add(const Duration(minutes: 20));
      final event = CalendarEvent(
        id: 'original',
        title: 'Original title',
        start: start,
        end: end,
        category: 'work',
      );
      CalendarEvent? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await Navigator.push<CalendarEvent>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        body: RecordEditor(
                          date: event.start.toLocal(),
                          kind: RecordKind.event,
                          event: event,
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Edited title');
      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(saved?.title, 'Edited title');
      expect(saved?.start, start.toLocal());
      expect(saved?.end, end.toLocal());
    });
  }
}
