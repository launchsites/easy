import 'package:easy/tasks/recurring_task.dart';
import 'package:easy/tasks/task_repeat_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'repeat settings save separately controlled reminder preference',
    (tester) async {
      TaskRepeatSettings? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open repeat settings'),
                onPressed: () async {
                  result = await showTaskRepeatEditor(
                    context,
                    startDate: DateTime(2026, 11, 24),
                    initialRule: InternalRecurrenceRule(
                      frequency: InternalRecurrenceFrequency.daily,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open repeat settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reminder preference'));
      await tester.tap(find.text('Reminder preference'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text('Delivery depends on this device’s reminder settings.'),
      );
      expect(
        find.text('Delivery depends on this device’s reminder settings.'),
        findsOneWidget,
      );
      expect(result, isNull);
      await tester.tap(find.text('Save repeat settings'));
      await tester.pumpAndSettle();
      expect(result?.rule.frequency, InternalRecurrenceFrequency.daily);
      expect(result?.startDate, DateTime(2026, 11, 24));
      expect(result?.reminder?.minuteOfDay, 9 * 60);
    },
  );

  testWidgets('scope picker returns an explicit series choice', (tester) async {
    InternalOccurrenceScope? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Skip'),
              onPressed: () async {
                result = await showTaskOccurrenceScopeDialog(
                  context,
                  skipping: true,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Skip repeating task'), findsOneWidget);
    await tester.tap(find.text('Entire series'));
    await tester.pumpAndSettle();
    expect(result, InternalOccurrenceScope.series);
  });
}
