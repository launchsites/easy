import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy/storage/attachment_store.dart';
import 'package:easy/storage/media_backup.dart';
import 'package:easy/storage/workspace_backup_page.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/ui_theme.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

WorkspaceSnapshot _fixture(int noteCount) => WorkspaceSnapshot(
  workspaceJson: jsonEncode({
    'tasks': [],
    'events': [],
    'notes': [
      for (var index = 0; index < noteCount; index++)
        {
          'id': 'note-$index',
          'title': 'A note',
          'body': 'Synthetic record',
          'updated': '2026-01-02T12:00:00',
        },
    ],
  }),
  gymSessionJson: const [],
  workoutPlanJson: const [],
);

void main() {
  late WorkspaceStore store;

  Future<void> display(
    WidgetTester tester, {
    required Future<Uint8List?> Function() pick,
    Future<void> Function(Uint8List, String)? export,
    Future<void> Function(WorkspaceRevision)? restored,
    WorkspaceMediaBackupUiSupport? media,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: WorkspaceBackupPage(
          store: store,
          pickBackup: pick,
          exportBackup: export ?? (_, _) async {},
          onRestored: restored ?? (_) async {},
          media: media,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openStore() async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    store = await openPreferenceWorkspaceStore(
      preferences: SharedPreferencesAsync(),
      readLegacy: () async => _fixture(2),
    );
  }

  testWidgets(
    'plain backup previews at narrow widths and restores only after confirmation',
    (tester) async {
      await openStore();
      _phone(tester);
      final file = await store.createBackup();
      await store.save(WorkspaceMutation.replace(_fixture(1)));
      WorkspaceRevision? callback;
      var picks = 0;
      await display(
        tester,
        pick: () async {
          picks++;
          return file;
        },
        restored: (revision) async => callback = revision,
      );
      expect(picks, 0);
      await tester.tap(find.text('Open a backup'));
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(find.text('Restore preview'), findsOneWidget);
      expect(find.text('Checksum-verified backup'), findsOneWidget);
      expect((await store.read()).revision, 2);
      expect(callback, isNull);

      await _review(tester);
      expect(find.text('Restore this backup?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await store.read()).revision, 2);
      expect(callback, isNull);

      await _review(tester);
      await tester.tap(find.text('Restore records'));
      await tester.pumpAndSettle();
      expect(callback?.revision, 3);
      expect(callback?.snapshot.workspaceJson, _fixture(2).workspaceJson);
      final recovery = await store.previewBackup(
        (await store.readRecoveryBackup())!,
      );
      expect(recovery.snapshot.workspaceJson, _fixture(1).workspaceJson);
    },
  );

  testWidgets(
    'concurrent edits invalidate a preview before it can overwrite records',
    (tester) async {
      await openStore();
      final file = await store.createBackup();
      WorkspaceRevision? callback;
      await display(
        tester,
        pick: () async => file,
        restored: (revision) async => callback = revision,
      );
      await tester.tap(find.text('Open a backup'));
      await tester.pumpAndSettle();
      expect(find.text('Restore preview'), findsOneWidget);

      await store.save(WorkspaceMutation.replace(_fixture(1)));
      await _review(tester);
      await tester.tap(find.text('Restore records'));
      await tester.pumpAndSettle();

      expect(find.text('Restore preview'), findsNothing);
      expect(find.textContaining('changed after this preview'), findsOneWidget);
      expect(callback, isNull);
      expect(
        (await store.read()).snapshot.workspaceJson,
        _fixture(1).workspaceJson,
      );
      expect(await store.readRecoveryBackup(), isNull);
    },
  );

  testWidgets(
    'export starts with an obscured, verified passphrase and does not export when cancelled',
    (tester) async {
      await openStore();
      _phone(tester);
      var exports = 0;
      await display(
        tester,
        pick: () async => null,
        export: (_, _) async => exports++,
      );
      await tester.tap(find.text('Export encrypted backup'));
      await tester.pumpAndSettle();
      expect(find.text('Protect your backup'), findsOneWidget);
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      expect(
        tester
            .widgetList<TextField>(fields)
            .every((field) => field.obscureText),
        isTrue,
      );
      await tester.enterText(fields.at(0), 'first synthetic phrase');
      await tester.enterText(fields.at(1), 'different phrase');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter the same passphrase again.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(exports, 0);
      expect(find.text('Protect your backup'), findsNothing);
    },
  );

  testWidgets(
    'recovery is a separate preview that never reverts without consent',
    (tester) async {
      await openStore();
      final original = await store.previewBackup(await store.createBackup());
      await store.save(WorkspaceMutation.replace(_fixture(1)));
      await store.restoreBackup(original, expectedRevision: 2);
      await display(tester, pick: () async => null);
      await tester.tap(find.text('Recovery point'));
      await tester.pumpAndSettle();
      expect(find.text('Previous workspace'), findsOneWidget);
      expect((await store.read()).revision, 3);
      expect(
        (await store.read()).snapshot.workspaceJson,
        original.snapshot.workspaceJson,
      );
    },
  );

  testWidgets('media export and restore use one reviewed, streamed file path', (
    tester,
  ) async {
    await openStore();
    _phone(tester);
    final (
      folder,
      scratch,
      original,
      destination,
      photo,
    ) = (await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('easy-backup-page-');
      final scratch = await Directory.fromUri(folder.uri.resolve('staging'))
          .create();
      final original = (await openAttachmentStore(
        directoryPath: folder.uri.resolve('original').toFilePath(),
      ))!;
      final destination = (await openAttachmentStore(
        directoryPath: folder.uri.resolve('destination').toFilePath(),
      ))!;
      final photo = await original.putBytes(_photo, kind: AttachmentKind.photo);
      return (folder, scratch, original, destination, photo);
    }))!;
    addTearDown(() async {
      await original.close();
      await destination.close();
      await folder.delete(recursive: true);
    });
    final record = _fixture(2);
    final withPhoto = WorkspaceSnapshot(
      workspaceJson: jsonEncode({
        ...(jsonDecode(record.workspaceJson) as Map<String, dynamic>),
        'nutrition': {
          'version': 1,
          'foods': [],
          'meals': [
            {
              'id': 'photo-meal',
              'name': 'Lunch',
              'eatenAt': '2026-11-24T03:00:00Z',
              'draft': true,
              'portions': [],
              'photo': photo.toJson(),
            },
          ],
        },
      }),
      gymSessionJson: const [],
      workoutPlanJson: const [],
    );
    await store.save(WorkspaceMutation.replace(withPhoto));
    const passphrase = 'Synthetic backup page test';
    File? exported;
    String? stagePath;
    var pickerCalls = 0;
    var attachmentReads = 0;
    WorkspaceRevision? restored;
    await display(
      tester,
      pick: () async => throw StateError('Use the native file picker.'),
      export: (_, _) async => throw StateError('Use the streaming exporter.'),
      restored: (value) async => restored = value,
      media: WorkspaceMediaBackupUiSupport(
        scratchDirectory: scratch.path,
        loadAttachments: () async {
          attachmentReads++;
          return exported == null ? original : destination;
        },
        pickBackupFile: () async {
          pickerCalls++;
          return XFile(exported!.path);
        },
        saveMediaArchive: (archive) async {
          stagePath = archive.nativePath;
          expect(stagePath, endsWith('.easymedia'));
          final open = File(stagePath!);
          final input = await open.open();
          try {
            expect(isWorkspaceMediaBackup(await input.read(8)), isTrue);
          } finally {
            await input.close();
          }
          exported = await open.copy(
            folder.uri.resolve('chosen.easymedia').toFilePath(),
          );
        },
      ),
    );

    await tester.tap(find.text('Export encrypted backup'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), passphrase);
    await tester.enterText(fields.at(1), passphrase);
    const include = 'Include voice recordings and meal photos';
    final checkbox = find.widgetWithText(CheckboxListTile, include);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.tap(find.text('Continue'));
    await _untilVisible(tester, 'Password-protected backup with media saved.');
    expect(File(stagePath!).existsSync(), isFalse);
    expect(attachmentReads, 1);

    await store.save(WorkspaceMutation.replace(_fixture(1)));
    await tester.tap(find.text('Open a backup'));
    await _untilVisible(tester, 'Unlock backup');
    await tester.enterText(find.byType(TextField), passphrase);
    await tester.tap(find.text('Open'));
    await _untilVisible(tester, 'Restore preview');
    expect(find.text('Password-protected backup with media'), findsOneWidget);
    expect(find.text('Original files'), findsOneWidget);
    expect(pickerCalls, 1);
    expect(attachmentReads, 1);
    expect((await store.read()).revision, 3);

    await _review(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(restored, isNull);
    expect(attachmentReads, 1);
    await _review(tester);
    await tester.tap(find.text('Restore records'));
    await _untilVisible(
      tester,
      'Workspace restored. Your previous records are in Recovery point.',
    );
    expect(restored!.snapshot.workspaceJson, withPhoto.workspaceJson);
    expect(attachmentReads, 2);
    expect(
      await tester.runAsync(
        () async => (await destination.read(photo.id)).bytes,
      ),
      _photo,
    );
    expect(scratch.listSync(), isEmpty);
  });
}

final _photo = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+bB6sAAAAASUVORK5CYII=',
);

Future<void> _untilVisible(WidgetTester tester, String text) async {
  final finder = find.text(text);
  final busy = find.byType(CircularProgressIndicator);
  for (
    var attempt = 0;
    attempt < 500 && (finder.evaluate().isEmpty || busy.evaluate().isNotEmpty);
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(finder, findsOneWidget);
  expect(busy, findsNothing);
  await tester.pumpAndSettle();
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 650);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _review(WidgetTester tester) async {
  final review = find.text('Review restore');
  await tester.ensureVisible(review);
  await tester.pumpAndSettle();
  await tester.tap(review);
  await tester.pumpAndSettle();
}
