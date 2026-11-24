import 'package:easy/mobile_home.dart';
import 'package:easy/task_model.dart';
import 'package:easy/today_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final today = DateUtils.dateOnly(DateTime.now());
  final agendas = [
    for (var index = 0; index < 15000; index++)
      TaskItem(
        id: 'agenda-$index',
        title: 'Agenda entry $index',
        category: 'work',
        date: today,
      ),
  ];

  for (final mobile in [false, true]) {
    testWidgets('${mobile ? 'mobile' : 'desktop'} agenda paints visible rows', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(
        mobile ? const Size(390, 844) : const Size(1440, 900),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TaskItem? marked;
      void onToggle(TaskItem task) => marked = task;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: mobile
                ? MobileHome(
                    date: today,
                    mode: null,
                    note: null,
                    events: const [],
                    tasks: agendas,
                    modeControl: const SizedBox.shrink(),
                    onNoteTap: () {},
                    onEventTap: (_) {},
                    onTaskTap: (_) {},
                    onTaskToggle: onToggle,
                    onCalendarTap: () {},
                  )
                : TodayPage(
                    date: today,
                    events: const [],
                    tasks: agendas,
                    onEventTap: (_) {},
                    onTaskTap: (_) {},
                    onTaskToggle: onToggle,
                  ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Agenda entry 0'), findsOneWidget);
      expect(find.text('Agenda entry 14999'), findsNothing);
      expect(find.byType(Checkbox).evaluate(), hasLength(lessThan(40)));
      await tester.tap(find.byType(Checkbox).first);
      expect(marked, same(agendas.first));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1300));
      await tester.pumpAndSettle();
      expect(find.text('Agenda entry 0'), findsNothing);
      expect(find.byType(Checkbox).evaluate().length, inInclusiveRange(1, 40));
      expect(tester.takeException(), isNull);
    });
  }
}
