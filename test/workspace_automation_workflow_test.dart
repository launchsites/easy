import 'package:easy/automation/automation.dart';
import 'package:easy/calendar_page.dart';
import 'package:easy/calendar_sources/calendar_settings_page.dart';
import 'package:easy/calendar_sources/ics_import_export.dart';
import 'package:easy/calendar_sources/ics_workspace.dart';
import 'package:easy/calendar_sources/internal_recurrence.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _sourceTitle = 'Finish research';
const _actionTitle = 'Write a follow-up';

void main() {
  setUp(() {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });

  for (final reopen in [false, true]) {
    testWidgets(
      'Task completion queues a draft and rechecks the source ($reopen)',
      (tester) async {
        final now = DateTime.now();
        await _mount(
          tester,
          WorkspaceData(
            tasks: [
              TaskItem(
                id: 'research',
                title: _sourceTitle,
                category: 'work',
                date: dateOnly(now),
              ),
            ],
            events: [],
            notes: [],
            sections: {
              'automationRules': _rules(
                AutomationTrigger.taskCompleted,
                now,
              ).toJson(),
            },
          ),
        );
        await _tap(tester, find.text(_sourceTitle));
        await _tap(tester, find.text('Mark done'));

        var saved = await _read();
        expect(saved.data.tasks.single.done, isTrue);
        expect(saved.rules.pending.single.action.text, _actionTitle);
        expect(saved.revision, 2);
        if (reopen) {
          await _tap(tester, find.text('Undo'));
          saved = await _read();
          expect(saved.data.tasks.single.done, isFalse);
        }

        await _tap(tester, find.text('Mode'));
        await _tap(tester, find.widgetWithText(MenuItemButton, 'Settings'));
        final ruleSettings = find.text('Automation rules');
        await tester.ensureVisible(ruleSettings);
        await tester.pumpAndSettle();
        await _tap(tester, ruleSettings.hitTestable());
        await _tap(tester, find.text('Outbox (1)'));
        await _tap(tester, find.text(_actionTitle));
        await _tap(tester, find.widgetWithText(FilledButton, 'Add task'));

        final result = await _read();
        if (reopen) {
          expect(
            find.text('The source changed. Review its current state.'),
            findsOneWidget,
          );
          expect(result.revision, saved.revision);
          expect(result.data.tasks, hasLength(1));
          expect(result.rules.pending, hasLength(1));
        } else {
          expect(result.revision, saved.revision + 1);
          expect(result.data.tasks.last.title, _actionTitle);
          expect(result.data.tasks.last.category, 'work');
          expect(result.rules.pending, isEmpty);
          expect(
            result.rules.drafts.single.status,
            AutomationDraftStatus.accepted,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Calendar triggers only while foreground and only for saved local events',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final now = DateTime.now();
      final start = now.subtract(const Duration(minutes: 1));
      final end = now.add(const Duration(minutes: 5));
      final imported = WorkspaceIcsCalendar(
        id: 'imported',
        name: 'Example calendar',
        document: exportIcsRecords([
          IcsExportRecord(
            uid: 'read-only',
            title: 'Read-only event',
            start: start,
            end: end,
          ),
        ]).encode(),
      );
      await _mount(
        tester,
        WorkspaceData(
          tasks: [],
          notes: [],
          events: [
            CalendarEvent(
              id: 'local',
              title: 'Work block',
              start: start,
              end: end,
              category: 'work',
            ),
          ],
          sections: {
            'automationRules': _rules(
              AutomationTrigger.acceptedEventStarted,
              now,
            ).toJson(),
            'importedCalendars': [imported.toJson()],
            'calendarPreferences': CalendarSourcePreferences(
              allCalendars: [imported.identity],
            ).toJson(),
          },
        ),
      );
      expect((await _read()).rules.pending, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpAndSettle();
      final active = await _read();
      expect(active.rules.pending.single.event.sourceId, 'local');
      expect(active.data.tasks, isEmpty);
      expect(active.revision, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        const EasyApp(openStore: openPreferenceWorkspaceStore),
      );
      await tester.pumpAndSettle();
      final restarted = await _read();
      expect(restarted.rules.pending.single.event.sourceId, 'local');
      expect(restarted.revision, active.revision);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'A recurring event triggers while a different calendar month is open',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final now = DateTime.now();
      const title = 'Repeated studio block';
      final series = InternalRecurringEvent(
        id: 'studio-series',
        event: InternalEventDraft.fromDates(
          title: title,
          start: now.toUtc().subtract(const Duration(minutes: 1)),
          end: now.toUtc().add(const Duration(minutes: 5)),
          category: 'work',
        ),
        rule: InternalRecurrenceRule(
          frequency: InternalRecurrenceFrequency.daily,
          count: 1,
        ),
      );
      await _mount(
        tester,
        WorkspaceData(
          tasks: [],
          notes: [],
          events: [],
          sections: {
            'recurringEvents': [series.toJson()],
            'automationRules': _rules(
              AutomationTrigger.acceptedEventStarted,
              now,
            ).toJson(),
          },
        ),
        viewport: const Size(1440, 900),
      );
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      final calendarLink = find.widgetWithText(InkWell, 'Calendar').first;
      tester.widget<InkWell>(calendarLink).onTap!();
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      final calendar = find.byType(CalendarPage);
      final later = plusDays(dateOnly(now), 60);
      tester.widget<CalendarPage>(calendar).onDateChanged(later);
      tester.binding.scheduleForcedFrame();
      await tester.pumpAndSettle();
      expect(tester.widget<CalendarPage>(calendar).date, later);
      expect((await _read()).rules.pending, isEmpty);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 100 && (await _read()).rules.pending.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      final result = await _read();
      expect(result.rules.pending.single.event.sourceTitle, title);
      expect(result.revision, 2);
      expect(tester.widget<CalendarPage>(calendar).date, later);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

AutomationData _rules(AutomationTrigger trigger, DateTime now) {
  final enabledAt = now.subtract(const Duration(minutes: 3));
  return AutomationData(
    rules: [
      AutomationRule(
        id: 'follow-up',
        name: 'Work follow-up',
        trigger: trigger,
        condition: AutomationCondition(
          category: trigger == AutomationTrigger.taskCompleted ? 'work' : null,
        ),
        action: AutomationAction(
          kind: AutomationActionKind.taskDraft,
          text: _actionTitle,
          category: 'work',
        ),
        enabledSince: enabledAt,
      ),
    ],
  ).withEnabled(true, enabledAt);
}

Future<void> _mount(
  WidgetTester tester,
  WorkspaceData workspace, {
  Size viewport = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await SharedPreferencesAsync().setString(
    'easy.workspace.v1',
    workspace.encode(),
  );
  await tester.pumpWidget(
    const EasyApp(openStore: openPreferenceWorkspaceStore),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<({int revision, WorkspaceData data, AutomationData rules})>
_read() async {
  final store = await openPreferenceWorkspaceStore(
    preferences: SharedPreferencesAsync(),
    readLegacy: () async => throw StateError('Expected the opened workspace'),
  );
  final revision = await store.read();
  await store.close();
  final data = WorkspaceData.decode(revision.snapshot.workspaceJson);
  return (
    revision: revision.revision,
    data: data,
    rules: AutomationData.fromJson(
      data.sections['automationRules']! as Map<String, Object?>,
    ),
  );
}
