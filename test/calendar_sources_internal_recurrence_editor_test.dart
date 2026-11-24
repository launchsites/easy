import 'package:easy/calendar_sources/internal_recurrence.dart';
import 'package:easy/calendar_sources/internal_recurrence_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('scope dialog returns the explicit future choice', (
    tester,
  ) async {
    InternalOccurrenceScope? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showInternalOccurrenceScopeDialog(
                    context,
                    skipping: false,
                  ),
              child: const Text('Open scope'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open scope'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('This and following occurrences'));
    await tester.pumpAndSettle();
    expect(result, InternalOccurrenceScope.future);
  });

  testWidgets('the rule form returns the chosen fields on save', (
    tester,
  ) async {
    InternalRecurrenceRule? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showInternalRecurrenceRuleEditor(context),
              child: const Text('Open rule'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open rule'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '2');
    await tester.tap(find.widgetWithText(FilterChip, 'Mon'));
    await tester.tap(find.widgetWithText(FilterChip, 'Thu'));
    await tester.tap(find.text('Never'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After a set number').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextFormField).last);
    await tester.enterText(find.byType(TextFormField).last, '4');
    expect(result, isNull);
    await tester.tap(find.text('Save repeat rule'));
    await tester.pumpAndSettle();
    expect(result?.frequency, InternalRecurrenceFrequency.weekly);
    expect(result?.interval, 2);
    expect(result?.weekdays, [DateTime.monday, DateTime.thursday]);
    expect(result?.count, 4);
  });
}
