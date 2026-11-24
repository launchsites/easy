import 'dart:typed_data';

import 'package:easy/storage/workspace_backup_page.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _deleted = (kind: WorkspaceHistoryRecordKind.task, id: 'removed');
const _added = (kind: WorkspaceHistoryRecordKind.task, id: 'added');

void main() {
  Future<void> display(
    WidgetTester tester,
    _HistoryFixture store,
    List<WorkspaceRevision> restored,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.35)),
          child: child!,
        ),
        home: WorkspaceBackupPage(
          store: store,
          pickBackup: () async =>
              throw StateError('History should not open a file picker.'),
          exportBackup: (_, _) async =>
              throw StateError('History should not export a file.'),
          onRestored: (revision) async => restored.add(revision),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'Version history');
    expect(find.text('Current workspace'), findsOneWidget);
  }

  testWidgets(
    'history opens from backup and reviews a selected record before restoring',
    (tester) async {
      final store = _HistoryFixture();
      final restored = <WorkspaceRevision>[];
      await display(tester, store, restored);
      await _tap(tester, 'Before planning');
      expect(find.text('Review version'), findsOneWidget);
      await _tap(tester, 'Deleted task');
      await _tap(tester, 'Review 1 record');
      expect(find.text('Restore 1 record?'), findsOneWidget);
      expect(store.selected, {_deleted});
      expect(store.commits, 0);
      await _tap(tester, 'Cancel');
      expect(restored, isEmpty);
      await _tap(tester, 'Review 1 record');
      await _tap(tester, 'Restore records');
      expect(store.commits, 1);
      expect(restored.single.revision, 3);
      expect(find.text('Version history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stale selection refreshes the review and active removals are spelled out',
    (tester) async {
      final store = _HistoryFixture();
      final restored = <WorkspaceRevision>[];
      await display(tester, store, restored);
      await _tap(tester, 'Before planning');
      await _tap(tester, 'New task');
      await _tap(tester, 'Review 1 record');
      expect(
        find.textContaining('1 selected record will be removed.'),
        findsOneWidget,
      );
      expect(store.selected, {_added});
      store.revision++;
      await _tap(tester, 'Restore records');
      expect(restored, isEmpty);
      expect(store.commits, 0);
      expect(
        find.text('The workspace changed. Review the updated changes.'),
        findsOneWidget,
      );
      expect(find.text('Review selection'), findsOneWidget);
    },
  );

  testWidgets(
    'naming saves an explicit point and the full-version restore still requires confirmation',
    (tester) async {
      final store = _HistoryFixture();
      await display(tester, store, []);
      await _tap(tester, 'Name current version');
      await tester.enterText(find.byType(TextField), 'Before next changes');
      await _tap(tester, 'Save name');
      expect(store.name, 'Before next changes');
      expect(find.text('Before next changes'), findsOneWidget);
      await _tap(tester, 'Before planning');
      await _tap(tester, 'Restore whole version');
      expect(find.text('Restore the whole version?'), findsOneWidget);
      expect(store.wholePreviews, 1);
      expect(store.commits, 0);
      await _tap(tester, 'Cancel');
      expect(store.commits, 0);
    },
  );
}

Future<void> _tap(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _HistoryFixture implements WorkspaceHistoryStore {
  int revision = 2;
  int commits = 0;
  int wholePreviews = 0;
  String? name;
  Set<WorkspaceHistoryRecordKey> selected = {};

  static final _saved = WorkspaceSnapshot(
    workspaceJson: '{"events":[],"tasks":[],"notes":[]}',
    gymSessionJson: const [],
    workoutPlanJson: const [],
  );
  static const _changes = [
    WorkspaceHistoryRecordChange(
      key: _deleted,
      title: 'Deleted task',
      reversion: WorkspaceHistoryReversion.recoverMissing,
    ),
    WorkspaceHistoryRecordChange(
      key: _added,
      title: 'New task',
      reversion: WorkspaceHistoryReversion.removeAdded,
    ),
  ];

  final _date = DateTime.utc(2026, 11, 23, 12);

  WorkspaceHistoryPoint _point(int version, String? label) =>
      WorkspaceHistoryPoint(
        revision: version,
        recordedAt: _date.add(Duration(hours: version)),
        kind: 'edit',
        name: label,
      );

  void _expect(int? expected) {
    if (expected != null && expected != revision) {
      throw WorkspaceRevisionConflict(expected: expected, actual: revision);
    }
  }

  @override
  Future<List<WorkspaceHistoryPoint>> listHistory() async => [
    _point(revision, name),
    _point(1, 'Before planning'),
  ];

  @override
  Future<WorkspaceHistoryPoint> nameHistoryPoint(
    String name, {
    required int expectedRevision,
  }) async {
    _expect(expectedRevision);
    this.name = name;
    return _point(revision, name);
  }

  @override
  Future<WorkspaceHistoryDiff> diffHistoryPoint(
    int sourceRevision, {
    int offset = 0,
    int limit = 100,
    int? expectedRevision,
  }) async {
    _expect(expectedRevision);
    return WorkspaceHistoryDiff(
      sourceRevision: sourceRevision,
      expectedRevision: revision,
      totalChanges: _changes.length,
      changes: _changes.skip(offset).take(limit).toList(),
    );
  }

  WorkspaceBackupPreview _preview(int sourceRevision) => WorkspaceBackupPreview(
    snapshot: _saved,
    sourceRevision: sourceRevision,
    counts: const WorkspaceRecordCounts(
      events: 0,
      tasks: 0,
      notes: 0,
      gymSessions: 0,
      workoutPlans: 0,
    ),
  );

  @override
  Future<WorkspaceBackupPreview> previewHistoryPoint(int revision) async {
    wholePreviews++;
    return _preview(revision);
  }

  @override
  Future<WorkspaceHistorySelectionPreview> previewHistorySelection({
    required int sourceRevision,
    required int expectedRevision,
    required Set<WorkspaceHistoryRecordKey> records,
  }) async {
    _expect(expectedRevision);
    selected = records;
    return WorkspaceHistorySelectionPreview(
      expectedRevision: expectedRevision,
      backup: _preview(sourceRevision),
      changes: _changes
          .where((change) => records.contains(change.key))
          .toList(),
    );
  }

  @override
  Future<WorkspaceRevision> restoreBackup(
    WorkspaceBackupPreview preview, {
    required int expectedRevision,
    String? operationId,
  }) async {
    _expect(expectedRevision);
    commits++;
    return WorkspaceRevision(revision: ++revision, snapshot: _saved);
  }

  @override
  Future<WorkspaceRevision> read() async =>
      WorkspaceRevision(revision: revision, snapshot: _saved);

  @override
  Future<void> removeHistoryPointName(
    int revision, {
    required int expectedRevision,
  }) async {
    _expect(expectedRevision);
    name = null;
  }

  @override
  Future<void> close() async {}

  @override
  Future<Uint8List> createBackup() => throw UnimplementedError();

  @override
  Future<Uint8List?> readRecoveryBackup() async => null;

  @override
  Future<WorkspaceBackupPreview> previewBackup(Uint8List data) =>
      throw UnimplementedError();

  @override
  Future<WorkspaceRevision> save(
    WorkspaceMutation mutation, {
    int? expectedRevision,
    String? operationId,
  }) => throw UnimplementedError();
}
