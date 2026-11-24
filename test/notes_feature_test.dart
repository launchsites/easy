import 'package:easy/list_pages.dart';
import 'package:easy/notes/notes.dart';
import 'package:easy/record_editor.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('legacy notes preserve their plain text and stable ID', () {
    const raw = <String, dynamic>{
      'id': 'old-note',
      'title': 'Old note',
      'body': 'Line 1\r\n\r\nLine 2\n',
      'updated': '2026-11-24T10:05:04.000',
      'category': 'work',
      'noteToSelf': true,
    };
    final note = NoteItem.fromJson(raw);
    expect(note.toJson(), raw);
    expect(note.pinned, isFalse);
    expect(note.links, isEmpty);
    expect(note.tags, isEmpty);
  });

  test('internal links round trip encoded record IDs only', () {
    final link = NoteLink(kind: NoteLinkKind.task, id: 'a/b file #1');
    expect(NoteLink.fromMarkdown(link.markdownUri.toString()), link);
    for (final href in [
      'https://example.invalid/note',
      'file:///example/test',
      'easy://external/task/a',
      'easy:/task/a',
      'easy:task/a?name=sample',
      'easy:event/a#anchor',
      'easy:unsupported/a',
      'easy:task/a/b',
    ]) {
      expect(NoteLink.fromMarkdown(href), isNull, reason: href);
    }
  });

  testWidgets(
    'preview exposes canonical task and event links without loading media',
    (tester) async {
      final opened = <NoteLink>[];
      const task = NoteTarget(
        kind: NoteLinkKind.task,
        id: 'real/task',
        title: 'Office work',
      );
      const event = NoteTarget(
        kind: NoteLinkKind.event,
        id: 'real-event',
        title: 'Library visit',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Scaffold(
            body: NotePreview(
              note: NoteItem(
                id: 'markdown',
                title: 'Reference',
                body: [
                  '# Heading',
                  '',
                  '[Local reference](${task.link.markdownUri})',
                  '',
                  '[Unresolved record](easy:event/missing)',
                  '',
                  '[Outside link](https://example.invalid/note)',
                  '',
                  '![Remote picture](https://example.invalid/image.png)',
                  '',
                  '[Local file](file:///sample/image.png)',
                ].join('\n'),
                updated: DateTime(2026, 11, 24),
                links: [
                  event.link,
                  const NoteLink(
                    kind: NoteLinkKind.task,
                    id: 'deleted',
                    title: 'Previously linked task',
                  ),
                ],
              ),
              targets: const [task, event],
              onOpenLink: opened.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.text('Heading'), findsOneWidget);
      expect(find.text('Previously linked task'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Unresolved record'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Outside link'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, task.title));
      await tester.tap(find.widgetWithText(ListTile, event.title));
      expect(opened, [task.link, event.link]);
    },
  );

  testWidgets(
    'note editor saves Markdown, a folder, tags, pin and linked record',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final old = NoteItem(
        id: 'older',
        title: 'Weekly notes',
        body: 'Previous line',
        updated: DateTime(2026, 11, 23),
        category: 'work',
        noteToSelf: true,
      );
      const target = NoteTarget(
        kind: NoteLinkKind.task,
        id: 'plan-id',
        title: 'Write the plan',
      );
      NoteItem? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  saved = await showDialog<NoteItem>(
                    context: context,
                    builder: (_) => Dialog(
                      child: RecordEditor(
                        date: old.updated,
                        kind: RecordKind.note,
                        note: old,
                        noteTargets: const [target],
                      ),
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      final source = find.byKey(const ValueKey('note-markdown-source'));
      const markdown = '# Project brief\n\n- [ ] Check the outline\n';
      await tester.enterText(source, markdown);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Project brief'), findsOneWidget);
      await tester.tap(find.text('Edit text'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(source).controller?.text, markdown);

      await tester.tap(find.text('Organise'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Pin note'));
      await tester.tap(find.text('Pin note'));
      final folder = find.byKey(const ValueKey('note-folder'));
      await tester.ensureVisible(folder);
      await tester.enterText(folder, 'Studio');
      final tags = find.byKey(const ValueKey('note-tags'));
      await tester.ensureVisible(tags);
      await tester.enterText(tags, 'Plan, Draft, plan');

      final addLink = find.text('Link task or event');
      await tester.ensureVisible(addLink);
      await tester.tap(addLink);
      await tester.pumpAndSettle();
      await tester.tap(find.text(target.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(saved?.id, old.id);
      expect(saved?.category, 'work');
      expect(saved?.noteToSelf, isTrue);
      expect(saved?.body, markdown);
      expect(saved?.folder, 'Studio');
      expect(saved?.tags.map((tag) => tag.toLowerCase()), ['plan', 'draft']);
      expect(saved?.pinned, isTrue);
      expect(saved?.links, [target.link]);
      expect(NoteItem.fromJson(saved!.toJson()).toJson(), saved!.toJson());
    },
  );

  testWidgets(
    'pinned notes stay first, and folder and tag filtering work together',
    (tester) async {
      final earlier = NoteItem(
        id: 'pinned',
        title: 'Book ideas',
        body: 'Pick up the paper copy.',
        updated: DateTime(2026, 11, 22),
        pinned: true,
        folder: 'Reading',
        tags: const ['Library'],
      );
      final later = NoteItem(
        id: 'newer',
        title: 'Travel plan',
        body: 'Two stops to the station.',
        updated: DateTime(2026, 11, 24),
        folder: 'Travel',
        tags: const ['Plans'],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Scaffold(
            body: NotesPage(notes: [later, earlier], onNoteTap: (_) {}),
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text(earlier.title)).dy,
        lessThan(tester.getTopLeft(find.text(later.title)).dy),
      );

      await tester.tap(find.byTooltip('Filter notes'));
      await tester.pumpAndSettle();
      final folder = find.byType(DropdownButtonFormField<String>).first;
      await tester.tap(folder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reading').last);
      await tester.pumpAndSettle();
      final tag = find.byType(DropdownButtonFormField<String>).last;
      await tester.tap(tag);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plans').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('No matching notes'), findsOneWidget);

      await tester.tap(find.byTooltip('Filters applied'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text(earlier.title), findsOneWidget);
      expect(find.text(later.title), findsOneWidget);
    },
  );
}
