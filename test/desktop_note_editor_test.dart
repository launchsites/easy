import 'dart:async';

import 'package:easy/notes/desktop_note_editor.dart';
import 'package:easy/notes/note_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'inline Markdown saves after a pause and preserves note metadata',
    (tester) async {
      final original = _note('one', title: '');
      final host = _Host([original]);
      addTearDown(host.dispose);
      await tester.pumpWidget(host.widget(autofocus: true));
      await tester.pump();
      expect(tester.widget<TextField>(_title).focusNode!.hasFocus, isTrue);
      expect(host.writes, isEmpty);

      await tester.enterText(_body, 'alpha');
      await tester.pump(const Duration(milliseconds: 499));
      expect(host.writes, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      final saved = host.notes['one']!;
      expect(saved.title, 'Untitled');
      expect(saved.body, 'alpha');
      expect(saved.category, original.category);
      expect(saved.noteToSelf, original.noteToSelf);
      expect(saved.pinned, original.pinned);
      expect(saved.folder, original.folder);
      expect(saved.tags, original.tags);
      expect(saved.links, original.links);
      expect(_text(tester, _title), 'Untitled');
      await tester.pump(const Duration(seconds: 1));
      expect(host.writes, hasLength(1));

      final body = tester.widget<TextField>(_body).controller!;
      body.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();
      expect(body.text, '**alpha**');
      await tester.tap(find.byTooltip('Preview Markdown'));
      await tester.pumpAndSettle();
      expect(find.text('alpha', findRichText: true), findsOneWidget);
      expect(find.text('Linked records'), findsOneWidget);
      expect(host.notes['one']!.body, '**alpha**');
      expect(host.writes, hasLength(2));

      await tester.tap(find.byTooltip('Write Markdown'));
      await tester.pumpAndSettle();
      expect(_text(tester, _body), '**alpha**');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching notes keeps edits that arrive during a durable save', (
    tester,
  ) async {
    final host = _Host([_note('one'), _note('two', body: 'second note')]);
    addTearDown(host.dispose);
    final finishFirstWrite = Completer<void>();
    host.pauseNext = finishFirstWrite.future;
    await tester.pumpWidget(host.widget());

    await tester.enterText(_body, 'first draft');
    await tester.pump(const Duration(milliseconds: 500));
    expect(host.writes, [(id: 'one', before: '', body: 'first draft')]);
    await tester.enterText(_body, 'latest first draft');
    host.select('two');
    await tester.pump();
    expect(_text(tester, _body), 'second note');
    await tester.enterText(_body, 'edited second note');

    finishFirstWrite.complete();
    await tester.pump();
    expect(await host.edits.flush(), isTrue);
    await tester.pumpAndSettle();
    expect(host.writes, [
      (id: 'one', before: '', body: 'first draft'),
      (id: 'one', before: 'first draft', body: 'latest first draft'),
      (id: 'two', before: 'second note', body: 'edited second note'),
    ]);

    host.select('one');
    await tester.pumpAndSettle();
    expect(_text(tester, _body), 'latest first draft');
    expect(host.notes['two']!.body, 'edited second note');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed save keeps the editable draft available on return', (
    tester,
  ) async {
    final host = _Host([_note('one', body: 'previous'), _note('two')]);
    addTearDown(host.dispose);
    host.reject = true;
    await tester.pumpWidget(host.widget());
    await tester.enterText(_body, 'keep this draft');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Changes could not be saved.'), findsOneWidget);
    expect(host.notes['one']!.body, 'previous');

    host.select('two');
    await tester.pumpAndSettle();
    host.select('one');
    await tester.pumpAndSettle();
    expect(_text(tester, _body), 'keep this draft');
    expect(find.text('Changes could not be saved.'), findsOneWidget);

    host.reject = false;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(host.notes['one']!.body, 'keep this draft');
    expect(find.text('Changes could not be saved.'), findsNothing);

    // A fresh editor keeps the exact durable content without another write.
    final savedCount = host.writes.length;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host.widget());
    await tester.pumpAndSettle();
    expect(_text(tester, _body), 'keep this draft');
    expect(host.writes, hasLength(savedCount));
    expect(tester.takeException(), isNull);
  });
}

final _title = find.byType(TextField).at(0);
final _body = find.byType(TextField).at(1);

String _text(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

NoteItem _note(String id, {String? title, String body = ''}) => NoteItem(
  id: id,
  title: title ?? 'Note $id',
  body: body,
  updated: DateTime.utc(2026, 11, 24),
  category: 'work',
  pinned: true,
  noteToSelf: true,
  folder: 'Projects',
  tags: const ['Research'],
  links: const [
    NoteLink(kind: NoteLinkKind.task, id: 'task', title: 'Next steps'),
  ],
);

class _Host {
  _Host(List<NoteItem> initial)
    : notes = {for (final note in initial) note.id: note},
      selected = initial.first.id;

  final Map<String, NoteItem> notes;
  final writes = <({String id, String before, String body})>[];
  final updates = ValueNotifier(0);
  late final edits = DesktopNoteEdits(save: _write);
  String selected;
  bool reject = false;
  Future<void>? pauseNext;

  void select(String id) {
    selected = id;
    updates.value++;
  }

  Future<NoteItem> _write(NoteItem expected, String title, String body) async {
    writes.add((id: expected.id, before: expected.body, body: body));
    final pause = pauseNext;
    pauseNext = null;
    if (pause != null) await pause;
    if (reject) throw StateError('Synthetic storage failure.');
    final current = notes[expected.id]!;
    expect(current.body, expected.body);
    expect(current.title, expected.title);
    final saved = current.withContent(
      title: title.trim().isEmpty ? 'Untitled' : title,
      body: body,
      updated: current.updated.add(const Duration(seconds: 1)),
    );
    notes[saved.id] = saved;
    updates.value++;
    return saved;
  }

  Widget widget({bool autofocus = false}) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder(
        valueListenable: updates,
        builder: (context, _, _) => DesktopNoteEditor(
          note: notes[selected]!,
          edits: edits,
          autofocus: autofocus,
        ),
      ),
    ),
  );

  void dispose() {
    edits.dispose();
    updates.dispose();
  }
}
