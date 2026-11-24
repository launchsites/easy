import 'dart:collection';

import 'package:easy/list_pages.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a large Tasks snapshot stays lazy and reuses groups on resize', (
    tester,
  ) async {
    _viewport(tester);
    final tasks = _CountedTasks(100000);
    TaskItem? toggled;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Scaffold(
          body: TasksPage(
            tasks: tasks,
            onTaskTap: (_) {},
            onToggle: (task) => toggled = task,
          ),
        ),
      ),
    );
    final initialReads = tasks.reads;
    expect(initialReads, tasks.length);
    expect(find.byType(Checkbox).evaluate().length, lessThan(30));
    expect(find.text('Task 0'), findsOneWidget);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(tasks.reads, initialReads);
    expect(find.byType(Checkbox).evaluate().length, lessThan(45));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tasks.reads, initialReads);
    expect(find.text('Task 0').hitTestable(), findsNothing);
    expect(find.byType(Checkbox).evaluate().length, lessThan(45));
    await tester.tap(find.byType(Checkbox).hitTestable().first);
    expect(toggled, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long note previews cap layout text and preserve searchable words',
    (tester) async {
      _viewport(tester);
      final prefix = List.filled(384, '👩🏽‍💻').join();
      final body = '$prefix delivery receipt';
      final date = DateTime(2026, 11, 24);
      final notes = [
        NoteItem(
          id: 'second',
          title: 'Travel plan',
          body: 'delivery',
          updated: date,
        ),
        NoteItem(id: 'first', title: 'Parcel log', body: body, updated: date),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Scaffold(
            body: NotesPage(notes: notes, onNoteTap: (_) {}),
          ),
        ),
      );
      final metadata = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.textSpan?.toPlainText().contains('delivery receipt') ??
                  false),
        ),
      );
      final renderedText = metadata.textSpan!.toPlainText(
        includeSemanticsLabels: false,
      );
      expect(renderedText.endsWith('$prefix…'), isTrue);
      expect(metadata.textSpan!.toPlainText().endsWith(body), isTrue);

      await tester.tap(find.byTooltip('Search notes'));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.enterText(input, 'delivery');
      await tester.pump();
      expect(find.text('Parcel log'), findsOneWidget);
      expect(find.text('Travel plan'), findsOneWidget);
      await tester.enterText(input, 'delivery receipt');
      await tester.pump();
      expect(find.text('Parcel log'), findsOneWidget);
      expect(find.text('Travel plan'), findsNothing);
      await tester.enterText(input, 'delivery');
      await tester.pump();
      expect(find.text('Travel plan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

class _CountedTasks extends ListBase<TaskItem> {
  _CountedTasks(this.length);

  @override
  final int length;
  int reads = 0;

  @override
  set length(int value) => throw UnsupportedError('Read only');

  @override
  TaskItem operator [](int index) {
    RangeError.checkValidIndex(index, this);
    reads++;
    return TaskItem(id: '$index', title: 'Task $index', category: 'work');
  }

  @override
  void operator []=(int index, TaskItem value) =>
      throw UnsupportedError('Read only');
}
