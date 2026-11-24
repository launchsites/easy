import 'dart:io';

import 'package:easy/ai/ai_device_state.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });
  test(
    'device ledger revisions survive reopen and concurrent writers',
    () async {
      final directory = await Directory.systemTemp.createTemp('easy-ai-test-');
      addTearDown(() => directory.delete(recursive: true));
      final path = directory.uri.resolve('ledger.sqlite3').toFilePath();
      Future<AiDeviceState> open() => AiDeviceState.open(
        preferences: SharedPreferencesAsync(),
        databasePath: path,
      );
      final first = await open();
      final second = await open();
      try {
        expect(await first.read(), isNull);
        final races = await Future.wait([
          first.compareAndSwap(0, 'first reservation'),
          second.compareAndSwap(0, 'second reservation'),
        ]);
        expect(races.nonNulls.length, 1);
        final head = (await first.read())!;
        expect(head.revision, races.nonNulls.single);
        expect(await second.compareAndSwap(0, 'obsolete'), isNull);
        expect(
          await first.compareAndSwap(head.revision, 'settled usage'),
          isNotNull,
        );
      } finally {
        await first.close();
        await second.close();
      }
      final reopened = await open();
      try {
        expect((await reopened.read())?.value, 'settled usage');
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'restoring the workspace cannot roll a settled device budget back',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-restore-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final preferences = SharedPreferencesAsync();
      final workspace = await openWorkspaceStore(
        preferences: preferences,
        readLegacy: () async => WorkspaceSnapshot(
          workspaceJson: '{"events":[],"tasks":[],"notes":[]}',
          gymSessionJson: [],
          workoutPlanJson: [],
        ),
        databasePath: directory.uri.resolve('workspace.sqlite3').toFilePath(),
      );
      final ledger = await AiDeviceState.open(
        preferences: preferences,
        databasePath: directory.uri.resolve('ledger.sqlite3').toFilePath(),
      );
      try {
        final initial = await workspace.createBackup();
        final revision = (await workspace.read()).revision;
        await ledger.compareAndSwap(0, '£8 settled');
        await workspace.restoreBackup(
          await workspace.previewBackup(initial),
          expectedRevision: revision,
        );
        expect((await ledger.read())?.value, '£8 settled');
      } finally {
        await ledger.close();
        await workspace.close();
      }
    },
  );
}
