import 'dart:math';

import 'package:easy/search/search.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const noteKey = SearchKey(SearchRecordKind.note, 'n');
  const taskKey = SearchKey(SearchRecordKind.task, 't');
  const eventKey = SearchKey(SearchRecordKind.event, 'e');
  const source = [
    SearchDocument(
      key: noteKey,
      title: 'Café release plans',
      body: 'The café team collected rehearsal notes. 研究計画 for the morning.',
      categoryId: 'studio',
      categoryName: 'Studio work',
      pinned: true,
    ),
    SearchDocument(
      key: taskKey,
      title: 'Send rehearsal notes',
      body: 'Link the release folder.',
      categoryId: 'studio',
      categoryName: 'Studio work',
    ),
    SearchDocument(
      key: eventKey,
      title: 'Morning meeting',
      body: 'Discuss café release and office moves.',
      categoryId: 'personal',
      categoryName: 'Personal',
    ),
  ];

  test('field queries, type filters and ranking are deterministic', () {
    final index = SearchIndex.build(source);
    expect(
      index
          .search(const WorkspaceSearchQuery('cafe release'))
          .map((hit) => hit.document.key),
      [noteKey, eventKey],
    );
    expect(
      index
          .search(
            const WorkspaceSearchQuery(
              'title:"cafe release" body:notes category:studio type:note',
            ),
          )
          .single
          .document
          .key,
      noteKey,
    );
    expect(
      index
          .search(const WorkspaceSearchQuery('body:cafe type:event'))
          .single
          .document
          .key,
      eventKey,
    );
    expect(
      index
          .search(const WorkspaceSearchQuery('title:notes body:release'))
          .single
          .document
          .key,
      taskKey,
    );
    expect(
      index.search(const WorkspaceSearchQuery('type:unknown cafe')),
      isEmpty,
    );
    expect(
      index.search(const WorkspaceSearchQuery('qualifiedmissingword')),
      isEmpty,
    );
    expect(index.search(const WorkspaceSearchQuery('????')), isEmpty);
  });

  test('decomposed accents and interior CJK substrings stay searchable', () {
    final index = SearchIndex.build([
      ...source,
      const SearchDocument(
        key: SearchKey(SearchRecordKind.note, 'intl'),
        title: 'Résumé 東京の会議 Καλημέρα ملاحظات',
      ),
    ]);
    expect(
      index.search(const WorkspaceSearchQuery('resume')).single.document.key.id,
      'intl',
    );
    expect(
      index.search(const WorkspaceSearchQuery('会議')).single.document.key.id,
      'intl',
    );
    expect(
      index.search(const WorkspaceSearchQuery('計画')).single.document.key,
      noteKey,
    );
    expect(
      index
          .search(const WorkspaceSearchQuery('καλημέρ'))
          .single
          .document
          .key
          .id,
      'intl',
    );
    expect(
      index
          .search(const WorkspaceSearchQuery('ملاحظات'))
          .single
          .document
          .key
          .id,
      'intl',
    );
  });

  test('scope excludes hidden records without deleting saved references', () {
    final index = SearchIndex.build(source);
    var preferences = SearchPreferences()
        .opened(eventKey)
        .opened(noteKey)
        .withFavourite(eventKey, true);
    preferences = SearchPreferences.fromJson(preferences.toJson());
    expect(preferences.recent, [noteKey, eventKey]);
    expect(preferences.favourites, {eventKey});
    const studio = WorkspaceSearchQuery('cafe', allowedCategories: {'studio'});
    expect(
      index
          .search(studio, favourites: preferences.favourites)
          .map((hit) => hit.document.key),
      [noteKey],
    );
    const favourites = WorkspaceSearchQuery('', favouritesOnly: true);
    expect(
      index
          .search(favourites, favourites: preferences.favourites)
          .single
          .document
          .key,
      eventKey,
    );
    expect(
      index.search(
        const WorkspaceSearchQuery('cafe', kinds: {SearchRecordKind.task}),
      ),
      isEmpty,
    );
  });

  test('full-body indexing keeps bounded excerpts and valid Unicode', () {
    final body =
        '${'intro ' * 420}😀 relevant résumé details ${'more ' * 8500} lateMarker';
    final index = SearchIndex.build([
      SearchDocument(key: noteKey, title: 'Long note', body: body),
    ]);
    final nearby = index
        .search(const WorkspaceSearchQuery('resume'))
        .single
        .snippet;
    expect(nearby, contains('résumé details'));
    expect(nearby.length, lessThanOrEqualTo(158));
    final far = index.search(const WorkspaceSearchQuery('lateMarker')).single;
    expect(far.document.key, noteKey);
    expect(far.snippet.length, lessThanOrEqualTo(158));
    final emoji = searchSnippet('😀' * 110);
    expect(emoji.runes, isNot(contains(0xfffd)));
    expect(emoji.length, lessThanOrEqualTo(158));
  });

  test('100k synthetic tasks, events and notes find equivalent scoped targets', () {
    final docs = [
      for (var index = 0; index < 100000; index++)
        SearchDocument(
          key: SearchKey(SearchRecordKind.values[index % 3], 'item-$index'),
          title:
              'Project ${index % 41} ${['Client handoff', 'Studio review', 'Workshop notes'][index % 3]}',
          body:
              'Review the prototype after the morning session. Check reference $index before the deadline.',
          categoryId: index.isEven ? 'work' : 'study',
          categoryName: index.isEven ? 'Work' : 'Study',
          date: DateTime(2026, 11, 24 - index % 365),
        ),
    ];
    final index = SearchIndex.build(docs);
    expect(index.documentCount, 100000);
    expect(
      index
          .search(
            const WorkspaceSearchQuery('body:"reference 96701" type:note'),
          )
          .single
          .document
          .key
          .id,
      'item-96701',
    );
    expect(
      index.search(
        const WorkspaceSearchQuery('body:"reference 96701" type:task'),
      ),
      isEmpty,
    );
    expect(
      index
          .search(
            const WorkspaceSearchQuery('title:project category:work'),
            limit: 20,
          )
          .length,
      20,
    );
    expect(
      index.search(const WorkspaceSearchQuery('someMissingRecord2026')),
      isEmpty,
    );
  });

  test(
    'posting intersections agree with direct matching across query orders',
    () {
      final random = Random(70285);
      final fields = ['project', 'provider', 'progress', 'studio', 'sturdy'];
      final records = [
        for (var slot = 0; slot < 580; slot++)
          (
            title: List.generate(
              2,
              (_) => fields[random.nextInt(fields.length)],
            ),
            body: List.generate(
              3,
              (_) => fields[random.nextInt(fields.length)],
            ),
            key: SearchKey(SearchRecordKind.values[slot % 3], 'record-$slot'),
            category: slot % 4 == 0 ? 'studio' : 'study',
          ),
      ];
      final index = SearchIndex.build([
        for (final record in records)
          SearchDocument(
            key: record.key,
            title: record.title.join(' '),
            body: record.body.join(' '),
            categoryId: record.category,
          ),
      ]);
      for (final title in ['proj', 'prov', 'progre']) {
        for (final body in ['stu', 'study', 'pro']) {
          final expected = {
            for (final record in records)
              if (record.key.kind == SearchRecordKind.event &&
                  record.category == 'studio' &&
                  record.title.any((term) => term.startsWith(title)) &&
                  record.body.any((term) => term.startsWith(body)) &&
                  record.body.contains('provider'))
                record.key,
          };
          for (final text in [
            'type:event title:$title body:$body body:provider',
            'body:provider body:$body title:$title type:event',
          ]) {
            final query = WorkspaceSearchQuery(
              text,
              allowedCategories: {'studio'},
            );
            expect(
              index
                  .search(query, limit: 100)
                  .map((hit) => hit.document.key)
                  .toSet(),
              expected,
              reason: text,
            );
          }
        }
      }
    },
  );

  testWidgets(
    'compact search shows pinned records, filters, and records a chosen result',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var preferences = SearchPreferences().opened(eventKey);
      SearchDocument? chosen;
      final index = buildSearchIndex(source);
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  chosen = await showDialog<SearchDocument>(
                    context: context,
                    builder: (_) => WorkspaceSearchDialog(
                      index: index,
                      preferences: preferences,
                      allowedCategories: const {'studio'},
                      onPreferencesChanged: (value) => preferences = value,
                    ),
                  );
                },
                child: const Text('Open search'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Morning meeting'), findsNothing);
      await tester.enterText(find.byType(TextField), 'rehearsal');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('Café release plans'), findsOneWidget);
      expect(find.text('Send rehearsal notes'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Tasks'));
      await tester.pumpAndSettle();
      expect(find.text('Café release plans'), findsNothing);
      await tester.tap(find.byTooltip('Add to favourites'));
      await tester.pumpAndSettle();
      expect(preferences.favourites, {taskKey});
      await tester.tap(find.text('Send rehearsal notes'));
      await tester.pumpAndSettle();
      expect(chosen?.key, taskKey);
      expect(preferences.recent, [taskKey, eventKey]);
      expect(tester.takeException(), isNull);
    },
  );
}
