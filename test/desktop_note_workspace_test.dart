import 'dart:convert';

import 'package:easy/list_pages.dart';
import 'package:easy/main.dart';
import 'package:easy/notes/desktop_note_editor.dart';
import 'package:easy/record_editor.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'desktop note edits and a typed New draft survive workspace reopen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);

      final original = NoteItem(
        id: 'project-log',
        title: 'Project log',
        body: 'Original body',
        updated: DateTime.utc(2026, 11, 24),
        pinned: true,
        folder: 'Projects',
        tags: const ['Research'],
      );
      final preferences = SharedPreferencesAsync();
      await preferences.setString(
        'easy.workspace.v1',
        jsonEncode({
          'events': [],
          'tasks': [],
          'notes': [original.toJson()],
        }),
      );
      Future<List<NoteItem>> savedNotes() async {
        final store = await openPreferenceWorkspaceStore(
          preferences: preferences,
          readLegacy: () async =>
              throw StateError('Expected an initialized store.'),
        );
        try {
          return WorkspaceData.decode(
            (await store.read()).snapshot.workspaceJson,
          ).notes;
        } finally {
          await store.close();
        }
      }

      const app = EasyApp(openStore: openPreferenceWorkspaceStore);
      final editor = find.byType(DesktopNoteEditor);
      final fields = find.descendant(
        of: editor,
        matching: find.byType(TextField),
      );
      final projectRow = find.descendant(
        of: find.byType(NotesPage),
        matching: find.text('Project log'),
      );
      Future<void> navigate(String name) async {
        await tester.tap(find.text(name).first);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await navigate('Notes');
      await tester.tap(projectRow);
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(find.byType(RecordEditor), findsNothing);
      await tester.enterText(fields.at(1), '# Next steps\n- Draft the outline');
      await navigate('Tasks');
      final edited = (await savedNotes()).single;
      expect(edited.id, original.id);
      expect(edited.body, '# Next steps\n- Draft the outline');
      expect(edited.pinned, original.pinned);
      expect(edited.folder, original.folder);
      expect(edited.tags, original.tags);

      await navigate('Notes');
      await tester.tap(find.text('New'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(tester.widget<TextField>(fields.first).controller!.text, isEmpty);
      expect(await savedNotes(), hasLength(1));
      await tester.enterText(fields.at(1), 'A new **inline** draft');
      await navigate('Tasks');
      final notes = await savedNotes();
      expect(notes, hasLength(2));
      expect(
        notes.singleWhere((note) => note.id != original.id).body,
        'A new **inline** draft',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await navigate('Notes');
      await tester.tap(projectRow);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        edited.body,
      );
      expect(find.byType(RecordEditor), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
