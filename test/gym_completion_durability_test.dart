import 'dart:async';

import 'package:easy/automation/automation.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const _storageKey = 'easy.test.gym-completion-durability';

void main() {
  testWidgets('a rejected finish retains the live workout for a saved retry', (
    tester,
  ) async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    final platform = _RejectingPreferences();
    SharedPreferencesAsyncPlatform.instance = platform;
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final now = DateTime.now();
    final session = GymSession.start(
      now: now.subtract(const Duration(minutes: 11)),
    );
    final enabledAt = now.subtract(const Duration(minutes: 3));
    final rules = AutomationData(
      rules: [
        AutomationRule(
          id: 'workout-follow-up',
          name: 'Plan next session',
          trigger: AutomationTrigger.workoutFinished,
          condition: AutomationCondition(category: 'gym'),
          action: AutomationAction(
            kind: AutomationActionKind.taskDraft,
            text: 'Review the next training session',
            category: 'gym',
          ),
          enabledSince: enabledAt,
        ),
      ],
    ).withEnabled(true, enabledAt);
    late WorkspaceStore store;
    await tester.pumpWidget(
      EasyApp(
        openStore: ({required preferences, required readLegacy}) async =>
            store = await openPreferenceWorkspaceStore(
              preferences: preferences,
              key: _storageKey,
              readLegacy: () async => WorkspaceSnapshot(
                workspaceJson: WorkspaceData(
                  events: [],
                  tasks: [],
                  notes: [],
                  sections: {'automationRules': rules.toJson()},
                ).encode(),
                gymSessionJson: [session.encode()],
                workoutPlanJson: [],
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Gym'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume').hitTestable());
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byType(GymSessionPage),
      matching: find.byType(TextField),
    );
    await tester.enterText(input, 'Stretch');
    await tester.tap(find.byTooltip('Log entry').hitTestable());
    await tester.pumpAndSettle();
    final prior = await store.read();
    expect(_session(prior).entries.single.title, 'Stretch');
    expect(_session(prior).finished, isFalse);

    const draft = 'Try shorter rest next set';
    await tester.enterText(input, draft);
    final finish = find.widgetWithText(TextButton, 'Finish');
    final shortcut = tester.widget<TextButton>(finish).onPressed!;
    final rejectWrite = Completer<void>();
    platform.rejectNextWrite = rejectWrite.future;
    await tester.tap(finish.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Discard draft and finish?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Finish').hitTestable());
    await tester.pumpAndSettle();
    expect(platform.rejectedWrites, 1);
    final claimedBeforeSave = find
        .text('Session complete')
        .evaluate()
        .isNotEmpty;
    final draftDuringSave = tester
        .widgetList<TextField>(input)
        .firstOrNull
        ?.controller
        ?.text;
    final pendingFinish = tester.widgetList<TextButton>(finish).firstOrNull;
    final canEditDuringSave = find
        .byTooltip('Log entry')
        .hitTestable()
        .evaluate()
        .isNotEmpty;
    shortcut();
    await tester.pump();
    expect(find.text('Discard draft and finish?'), findsNothing);

    rejectWrite.complete();
    await tester.pumpAndSettle();
    expect(platform.rejectedWrites, 1);
    final afterFailure = await store.read();
    expect(afterFailure.revision, prior.revision);
    expect(afterFailure.snapshot.gymSessionJson, prior.snapshot.gymSessionJson);
    expect(afterFailure.snapshot.workspaceJson, prior.snapshot.workspaceJson);
    expect(claimedBeforeSave, isFalse);
    expect(draftDuringSave, draft);
    expect(pendingFinish, isNotNull);
    expect(pendingFinish!.onPressed, isNull);
    expect(canEditDuringSave, isFalse);
    expect(find.text('Session complete'), findsNothing);
    expect(find.byTooltip('Log entry').hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, draft);
    expect(find.text('Stretch'), findsOneWidget);
    expect(
      find.textContaining('could not be saved').hitTestable(),
      findsOneWidget,
    );

    await tester.tap(finish.hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Finish').hitTestable());
    await tester.pumpAndSettle();
    final retried = await store.read();
    expect(retried.revision, prior.revision + 1);
    expect(_session(retried).finished, isTrue);
    expect(_session(retried).startedAt, _session(prior).startedAt);
    expect(_session(retried).entries.single.title, 'Stretch');
    final saved = WorkspaceData.decode(retried.snapshot.workspaceJson);
    final savedRules = AutomationData.fromJson(
      saved.sections['automationRules']! as Map<String, Object?>,
    );
    expect(
      savedRules.pending.single.event.occurredAt,
      _session(retried).finishedAt,
    );
    expect(saved.tasks, isEmpty);
    expect(find.text('Session complete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed save fits above the scaled landscape keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(568, 320);
    tester.view.viewInsets = const FakeViewPadding(bottom: 130);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);

    final write = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: child!,
          ),
        ),
        home: GymSessionPage(
          session: GymSession.start(),
          onChanged: (_) {},
          onFinish: (_, _) => write.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Log entry').hitTestable(), findsNothing);

    write.completeError(StateError('Synthetic workout save failure'));
    await tester.pumpAndSettle();
    expect(find.text('Save failed').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Log entry').hitTestable(), findsOneWidget);
    expect(find.text('Finish').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pump();
      expect(
        find.bySemanticsLabel('The workout could not be saved.'),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });
}

GymSession _session(WorkspaceRevision revision) =>
    GymSession.decode(revision.snapshot.gymSessionJson.single);

final class _RejectingPreferences extends InMemorySharedPreferencesAsync {
  _RejectingPreferences() : super.empty();

  Future<void>? rejectNextWrite;
  var rejectedWrites = 0;

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    if (rejectNextWrite case final pending? when key == _storageKey) {
      rejectNextWrite = null;
      rejectedWrites++;
      await pending;
      throw StateError('Synthetic workout save failure');
    }
    return super.setString(key, value, options);
  }
}
