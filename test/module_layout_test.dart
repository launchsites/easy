import 'package:easy/automation/automation.dart';
import 'package:easy/health/health.dart';
import 'package:easy/insights/insights.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/review/review.dart';
import 'package:easy/search/search.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime(2026, 11, 24, 10);
  const title = 'An intentionally long synthetic record title for wrapping';
  final activity = InsightActivity(
    id: 'active',
    category: 'work',
    spans: [InsightWindow(now, now.add(const Duration(hours: 1)))],
  );
  final note = NoteItem(
    id: 'note',
    title: title,
    body: 'Sample note text with an unrelated second line.\nMore details.',
    updated: now,
    pinned: true,
    folder: 'A long folder label',
  );
  final document = SearchDocument(
    key: const SearchKey(SearchRecordKind.note, 'note'),
    title: note.title,
    body: note.body,
    categoryId: 'work',
    categoryName: 'Long category display name',
    date: now,
    pinned: true,
  );
  final viewports = [
    ('320 normal', const Size(320, 568), 1.0, TextDirection.ltr),
    ('320 large RTL', const Size(320, 568), 2.0, TextDirection.rtl),
    ('390', const Size(390, 844), 1.2, TextDirection.ltr),
    ('landscape large', const Size(568, 320), 2.0, TextDirection.ltr),
    ('719', const Size(719, 800), 1.3, TextDirection.ltr),
    ('desktop', const Size(1440, 900), 1.0, TextDirection.ltr),
  ];
  final views = <(String, Widget Function())>[
    (
      'Notes',
      () => Scaffold(
        body: NotesPage(notes: [note], onNoteTap: (_) {}),
      ),
    ),
    (
      'Review',
      () => ReviewPage(
        data: ReviewData(),
        clock: () => now,
        onChanged: (_) async {},
        agendaForDay: (_) => ReviewAgenda(
          tasks: [ReviewTask(id: 'task', title: title, date: now)],
          events: [
            ReviewEvent(
              id: 'event',
              title: title,
              start: now,
              end: now.add(const Duration(hours: 1)),
            ),
          ],
        ),
        onRollForward: (_, _) async {},
      ),
    ),
    (
      'Insights',
      () => InsightsPage(
        activities: [activity],
        tasks: const [InsightTask(id: 'task', title: title, category: 'work')],
        clock: () => now,
      ),
    ),
    (
      'Health',
      () => HealthPage(
        data: HealthData(
          measurements: [
            BodyMeasurement(
              id: 'reading',
              kind: MeasurementKind.bodyWeight,
              unit: MeasurementUnit.kilograms,
              value: 73,
              recordedAt: now,
            ),
            BodyMeasurement(
              id: 'older',
              kind: MeasurementKind.bodyWeight,
              unit: MeasurementUnit.kilograms,
              value: 71,
              recordedAt: now.subtract(const Duration(days: 7)),
            ),
          ],
        ),
        onChanged: (_) async {},
        clock: () => now,
      ),
    ),
    (
      'Automations',
      () => AutomationPage(
        data: AutomationData(
          rules: [
            AutomationRule(
              id: 'rule',
              name: title,
              trigger: AutomationTrigger.taskCompleted,
              condition: AutomationCondition(),
              action: AutomationAction(
                kind: AutomationActionKind.taskDraft,
                text: title,
              ),
            ),
          ],
        ),
        onChange: (apply) async => apply(AutomationData()),
        clock: () => now,
      ),
    ),
    (
      'Search',
      () => Scaffold(
        body: WorkspaceSearchDialog(
          index: buildSearchIndex([document]),
          preferences: SearchPreferences(favourites: [document.key]),
          initialQuery: 'synthetic',
        ),
      ),
    ),
  ];

  for (final (viewport, size, scale, direction) in viewports) {
    for (final (name, build) in views) {
      testWidgets('$name fits $viewport', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: easyTheme(),
            home: build(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Directionality(textDirection: direction, child: child!),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
