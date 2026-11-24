import 'package:easy/automation/automation.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime.utc(2026, 11, 24, 12);
  final prior = now.subtract(const Duration(hours: 1));

  AutomationRule rule({
    AutomationTrigger trigger = AutomationTrigger.taskCompleted,
    AutomationCondition? condition,
    DateTime? enabledSince,
  }) => AutomationRule(
    id: 'follow-up',
    name: 'After the work is done',
    trigger: trigger,
    condition: condition ?? AutomationCondition(category: 'work'),
    action: AutomationAction(
      kind: AutomationActionKind.taskDraft,
      text: 'Prepare follow-up',
      category: 'work',
    ),
    enabledSince: enabledSince ?? prior,
  );

  AutomationEvent event({
    String occurrence = 'completion-1',
    int revision = 1,
    AutomationTrigger trigger = AutomationTrigger.taskCompleted,
    AutomationOrigin origin = AutomationOrigin.user,
    DateTime? at,
    DateTime? until,
    int? weekday,
    int? minute,
  }) => AutomationEvent(
    trigger: trigger,
    sourceId: 'canonical-task',
    occurrenceId: occurrence,
    sourceRevision: revision,
    occurredAt: at ?? now,
    eligibleUntil: until,
    category: 'work',
    sourceTitle: 'Original private task',
    origin: origin,
    wallWeekday: weekday,
    wallMinute: minute,
  );

  AutomationDispatch dispatch(
    AutomationData data,
    AutomationEvent input, {
    DateTime? clock,
    int? revision = 1,
    bool foreground = true,
    Set<AutomationTrigger>? enabled,
  }) => data.dispatch(
    input,
    now: clock ?? now,
    currentSourceRevision: revision,
    foreground: foreground,
    enabledTriggers: enabled,
  );

  test(
    'rules stay disabled until enabled and queue only typed unreviewed drafts',
    () {
      final closed = AutomationData(rules: [rule()]);
      final suppressed = dispatch(closed, event());
      expect(suppressed.status, AutomationDispatchStatus.disabled);
      expect(suppressed.data, same(closed));
      final open = closed.withEnabled(true, prior);
      final outcome = dispatch(open, event());
      expect(outcome.status, AutomationDispatchStatus.queued);
      final draft = outcome.addedDrafts.single;
      expect(draft.status, AutomationDraftStatus.pending);
      expect(draft.action.text, 'Prepare follow-up');
      expect(draft.action.kind, AutomationActionKind.taskDraft);
      expect(outcome.data.pending.single.id, draft.id);
    },
  );

  test('restart, revisions and retries cannot create duplicate drafts or approvals', () {
    final active = AutomationData(rules: [rule()]).withEnabled(true, prior);
    final stale = dispatch(active, event(), revision: 2);
    expect(stale.status, AutomationDispatchStatus.stale);
    expect(stale.data.pending, isEmpty);

    final first = dispatch(active, event()).data;
    final reopened = AutomationData.decode(first.encode());
    final replay = dispatch(reopened, event(revision: 2), revision: 2);
    expect(replay.status, AutomationDispatchStatus.replayed);
    expect(replay.data.pending.single.id, first.pending.single.id);
    final draft = replay.data.pending.single;
    expect(
      () => replay.data.reviewDraft(
        draft.id,
        status: AutomationDraftStatus.accepted,
        now: now,
        currentSourceRevision: 2,
      ),
      throwsFormatException,
    );

    final reviewed = replay.data.reviewDraft(
      draft.id,
      status: AutomationDraftStatus.accepted,
      now: now,
      currentSourceRevision: 1,
    );
    expect(reviewed.pending, isEmpty);
    expect(
      reviewed.reviewDraft(
        draft.id,
        status: AutomationDraftStatus.accepted,
        now: now,
      ),
      same(reviewed),
    );
    expect(
      () => reviewed.reviewDraft(
        draft.id,
        status: AutomationDraftStatus.dismissed,
        now: now,
      ),
      throwsFormatException,
    );
    final next = dispatch(
      reviewed,
      event(occurrence: 'completion-2', revision: 2),
      revision: 2,
    );
    expect(next.data.pending.single.event.occurrenceId, 'completion-2');
  });

  test('foreground start reconciliation has an exact eligibility window', () {
    final trigger = AutomationTrigger.acceptedEventStarted;
    final input = event(
      trigger: trigger,
      origin: AutomationOrigin.acceptedSchedule,
      until: now.add(const Duration(hours: 1)),
    );
    final state = AutomationData(rules: [rule(trigger: trigger)])
        .withEnabled(true, prior);
    expect(
      dispatch(
        state,
        input,
        clock: now.subtract(const Duration(seconds: 1)),
      ).status,
      AutomationDispatchStatus.future,
    );
    expect(
      dispatch(
        state,
        input,
        foreground: false,
        clock: now.add(const Duration(minutes: 20)),
      ).status,
      AutomationDispatchStatus.background,
    );
    expect(
      dispatch(
        state,
        input,
        clock: now.add(const Duration(minutes: 59)),
      ).status,
      AutomationDispatchStatus.queued,
    );
    expect(
      dispatch(state, input, clock: now.add(const Duration(hours: 1))).status,
      AutomationDispatchStatus.expired,
    );
    expect(
      dispatch(state, input, enabled: {AutomationTrigger.taskCompleted}).status,
      AutomationDispatchStatus.unsupported,
    );
    expect(
      dispatch(
        state,
        event(trigger: trigger, origin: AutomationOrigin.automation),
      ).status,
      AutomationDispatchStatus.unsupported,
    );
    expect(
      dispatch(
        state,
        event(trigger: trigger),
        clock: now.add(const Duration(minutes: 16)),
      ).status,
      AutomationDispatchStatus.expired,
    );
  });

  test('an overnight condition belongs to its start day', () {
    final condition = AutomationCondition(
      weekdays: const [DateTime.monday],
      startMinute: 22 * 60,
      endMinute: 2 * 60,
    );
    final active = AutomationData(rules: [rule(condition: condition)])
        .withEnabled(true, prior);
    expect(
      dispatch(active, event(weekday: DateTime.monday, minute: 22 * 60)).status,
      AutomationDispatchStatus.queued,
    );
    expect(
      dispatch(active, event(weekday: DateTime.tuesday, minute: 119)).status,
      AutomationDispatchStatus.queued,
    );
    expect(
      dispatch(active, event(weekday: DateTime.tuesday, minute: 120)).status,
      AutomationDispatchStatus.unmatched,
    );
    expect(
      dispatch(
        active,
        event(weekday: DateTime.tuesday, minute: 22 * 60),
      ).status,
      AutomationDispatchStatus.unmatched,
    );
  });

  test(
    'fall-back wall times preserve distinct confirmed instants through reload',
    () {
      final first = DateTime.parse('2026-10-25T01:30:00+01:00');
      final second = DateTime.parse('2026-10-25T01:30:00+00:00');
      final trigger = AutomationTrigger.acceptedEventStarted;
      final dawn = first.subtract(const Duration(hours: 1));
      final condition = AutomationCondition(
        weekdays: const [DateTime.sunday],
        startMinute: 60,
        endMinute: 120,
      );
      final active = AutomationData(
        rules: [
          rule(trigger: trigger, enabledSince: dawn, condition: condition),
        ],
      ).withEnabled(true, dawn);
      final firstInput = event(
        trigger: trigger,
        occurrence: 'fold-before',
        at: first,
        until: first.add(const Duration(hours: 3)),
        weekday: DateTime.sunday,
        minute: 90,
      );
      final secondInput = event(
        trigger: trigger,
        occurrence: 'fold-after',
        at: second,
        weekday: DateTime.sunday,
        minute: 90,
      );
      final saved = dispatch(active, firstInput, clock: first).data;
      final loaded = AutomationData.decode(saved.encode());

      expect(
        dispatch(loaded, firstInput, clock: second).status,
        AutomationDispatchStatus.replayed,
      );
      final finalData = dispatch(loaded, secondInput, clock: second).data;
      expect(finalData.pending.length, 2);
      expect(finalData.pending.map((draft) => draft.event.wallMinute), [
        90,
        90,
      ]);
      expect(
        finalData.pending.last.event.occurredAt.difference(
          finalData.pending.first.event.occurredAt,
        ),
        const Duration(hours: 1),
      );
    },
  );

  test(
    'capacity preserves all pending drafts and permits a retry after review',
    () {
      var data = AutomationData(rules: [rule()]).withEnabled(true, prior);
      for (var index = 0; index < AutomationData.maxPending; index++) {
        data = dispatch(data, event(occurrence: 'one-$index')).data;
      }
      final retry = event(occurrence: 'extra');
      final full = dispatch(data, retry);
      expect(full.status, AutomationDispatchStatus.capacity);
      expect(full.data, same(data));
      final cleared = data.reviewDraft(
        data.pending.first.id,
        status: AutomationDraftStatus.dismissed,
        now: now,
      );
      expect(
        dispatch(cleared, retry).data.pending.length,
        AutomationData.maxPending,
      );
    },
  );

  test('a clock rollback cannot bring a pruned historical event back', () {
    final start = now.subtract(const Duration(days: 2));
    var active = AutomationData(rules: [rule(enabledSince: start)])
        .withEnabled(true, start);
    final original = event(at: start);
    active = dispatch(active, original, clock: start).data;
    active = active.reviewDraft(
      active.pending.single.id,
      status: AutomationDraftStatus.dismissed,
      now: start,
    );
    final later = start.add(const Duration(days: 31));
    active = dispatch(
      active,
      event(occurrence: 'new', at: later),
      clock: later,
    ).data;
    expect(
      dispatch(active, original, clock: start).status,
      AutomationDispatchStatus.expired,
    );
  });

  testWidgets(
    'outbox approval requires an explicit user action at 320 pixels',
    (tester) async {
      _phone(tester);
      var data = dispatch(
        AutomationData(rules: [rule()]).withEnabled(true, prior),
        event(),
      ).data;
      final effects = <String>[];
      await tester.pumpWidget(
        _app(
          AutomationPage(
            data: data,
            clock: () => now,
            onChange: (update) async => data = update(data),
            onAcceptDraft: (id) async {
              effects.add(id);
              return data = data.reviewDraft(
                id,
                status: AutomationDraftStatus.accepted,
                now: now,
              );
            },
            categories: const {'work': 'Work'},
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Outbox (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare follow-up'));
      await tester.pumpAndSettle();
      expect(effects, isEmpty);
      await tester.tap(find.text('Add task'));
      await tester.pumpAndSettle();
      expect(effects, [data.drafts.single.id]);
      expect(find.text('No drafts waiting for review.'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'History'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Added'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new rule keeps the local feature and rule disabled by default',
    (tester) async {
      _phone(tester);
      var data = AutomationData();
      await tester.pumpWidget(
        _app(
          AutomationPage(
            data: data,
            clock: () => now,
            onChange: (update) async => data = update(data),
          ),
        ),
      );
      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Rule name'),
        'My rule',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Draft text'),
        'Do the next step',
      );
      await tester.tap(find.text('Save rule'));
      await tester.pumpAndSettle();
      expect(data.rules.single.name, 'My rule');
      expect(data.rules.single.enabled, isFalse);
      expect(data.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _app(Widget home) => MaterialApp(theme: easyTheme(), home: home);
