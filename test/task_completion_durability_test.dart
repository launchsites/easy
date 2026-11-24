import 'dart:convert';

import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const _title = 'Finish the studio handoff';
const _testStorageKey = 'easy.test.task-completion-durability';

void main() {
  testWidgets('rejected completion stays open and a retry can be undone', (
    tester,
  ) async {
    final (:store, :preferences) = await _openInspector(tester);
    final initial = await store.read();
    final original = _task(initial);
    preferences.rejectNextWrite = true;

    await _press(tester, 'Mark done');
    expect(preferences.rejectedWrites, 1);
    expect((await store.read()).revision, initial.revision);
    expect(_task(await store.read()), original);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(find.text('Mark done').hitTestable(), findsOneWidget);
    expect(find.text('Reopen'), findsNothing);
    expect(find.text('Task completed'), findsNothing);
    expect(
      find.text('Changes could not be saved on this device.').hitTestable(),
      findsOneWidget,
    );

    await _dismissSnack(tester);
    await _press(tester, 'Mark done');
    final saved = await store.read();
    expect(saved.revision, initial.revision + 1);
    final completed = _task(saved);
    final stamped = completed.remove('completedAt') as String?;
    expect(stamped, isNotNull);
    expect(DateTime.tryParse(stamped!)?.isUtc, isTrue);
    expect(completed, {...original, 'done': true});
    expect(find.text('Task completed').hitTestable(), findsOneWidget);

    await tester.tap(find.text('Undo').hitTestable());
    await tester.pumpAndSettle();
    final undone = await store.read();
    expect(undone.revision, saved.revision + 1);
    expect(undone.snapshot.workspaceJson, initial.snapshot.workspaceJson);
    expect(find.text('Mark done').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an old undo does not reopen a later completion', (tester) async {
    final (:store, preferences: _) = await _openInspector(tester);
    await _press(tester, 'Mark done');
    final first = await store.read();
    final originalUndo = tester
        .widget<SnackBarAction>(find.byType(SnackBarAction))
        .onPressed;

    await _dismissSnack(tester);
    await _press(tester, 'Reopen');
    await _dismissSnack(tester);
    await _press(tester, 'Mark done');
    final latest = await store.read();
    expect(latest.revision, first.revision + 2);
    expect(_task(latest)['completedAt'], isNot(_task(first)['completedAt']));

    originalUndo();
    await tester.pumpAndSettle();
    final retained = await store.read();
    expect(retained.revision, latest.revision);
    expect(retained.snapshot.workspaceJson, latest.snapshot.workspaceJson);
    expect(find.text('Reopen').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected mobile completion leaves the same sheet available', (
    tester,
  ) async {
    final (:store, :preferences) = await _openInspector(
      tester,
      size: const Size(320, 568),
    );
    final original = await store.read();
    preferences.rejectNextWrite = true;

    await _press(tester, 'Mark done');
    expect(find.text('Task could not be saved').hitTestable(), findsOneWidget);
    expect(find.text('Task completed'), findsNothing);
    expect(
      (await store.read()).snapshot.workspaceJson,
      original.snapshot.workspaceJson,
    );
    await _press(tester, 'Close');

    expect(find.text('Mark done'), findsOneWidget);
    await _press(tester, 'Mark done');
    final saved = await store.read();
    expect(saved.revision, original.revision + 1);
    expect(_task(saved)['done'], isTrue);
    expect(find.text('Mark done'), findsNothing);
    expect(find.text('Task completed').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<({WorkspaceStore store, _RejectingPreferences preferences})>
_openInspector(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final previousPlatform = SharedPreferencesAsyncPlatform.instance;
  final platform = _RejectingPreferences();
  SharedPreferencesAsyncPlatform.instance = platform;
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = previousPlatform);

  final today = dateOnly(DateTime.now());
  final workspace = WorkspaceData(
    events: [],
    notes: [],
    tasks: [
      TaskItem(
        id: 'handoff',
        title: _title,
        date: today,
        dueAt: DateTime(today.year, today.month, today.day, 22, 35).toUtc(),
        category: 'work',
        notes: 'The rehearsal checklist stays with the task.',
      ),
    ],
  );
  late WorkspaceStore store;
  await tester.pumpWidget(
    EasyApp(
      openStore: ({required preferences, required readLegacy}) async =>
          store = await openPreferenceWorkspaceStore(
            preferences: preferences,
            key: _testStorageKey,
            readLegacy: () async => WorkspaceSnapshot(
              workspaceJson: workspace.encode(),
              gymSessionJson: [],
              workoutPlanJson: [],
            ),
          ),
    ),
  );
  await tester.pumpAndSettle();
  if (size.width < 720) {
    await tester.tap(find.byTooltip('Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Tasks').hitTestable());
  } else {
    await tester.tap(find.text('Tasks').first);
  }
  await tester.pumpAndSettle();
  await tester.tap(find.text(_title).hitTestable());
  await tester.pumpAndSettle();
  expect(find.text('Mark done'), findsOneWidget);
  return (store: store, preferences: platform);
}

Future<void> _press(WidgetTester tester, String label) async {
  final button = find.widgetWithText(TextButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button.hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _dismissSnack(WidgetTester tester) async {
  tester
      .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
      .hideCurrentSnackBar();
  await tester.pumpAndSettle();
}

Map<String, Object?> _task(WorkspaceRevision state) {
  final document = jsonDecode(state.snapshot.workspaceJson) as Map;
  return Map<String, Object?>.from((document['tasks'] as List).single as Map);
}

final class _RejectingPreferences extends InMemorySharedPreferencesAsync {
  _RejectingPreferences() : super.empty();

  var rejectNextWrite = false;
  var rejectedWrites = 0;

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    if (key == _testStorageKey && rejectNextWrite) {
      rejectNextWrite = false;
      rejectedWrites++;
      throw StateError('Synthetic workspace write failure');
    }
    return super.setString(key, value, options);
  }
}
