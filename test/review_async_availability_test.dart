import 'dart:async';

import 'package:easy/review/review.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _today = DateTime(2026, 11, 24);

ReviewDayAvailability _knownAvailability(DateTime day, int minutes) =>
    deriveReviewDayAvailability(
      day: day,
      settings: SchedulingSettings(
        availability: [
          WeeklyAvailability(
            id: 'saved-hours',
            weekdays: [minutes == 0 ? nextReviewDay(day).weekday : day.weekday],
            startMinute: 540,
            endMinute: 540 + (minutes > 0 ? minutes : 45),
          ),
        ],
      ),
      categories: ['work'],
      events: [],
      calendarComplete: true,
    )!;

Widget _app({
  Future<ReviewDayAvailability?> Function(DateTime)? load,
  ReviewAgenda agenda = const ReviewAgenda(),
  TextDirection direction = TextDirection.ltr,
  double scale = 1,
}) => MaterialApp(
  theme: easyTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: ReviewPage(
    data: ReviewData(),
    initialDay: _today,
    agendaForDay: (_) => agenda,
    availabilityForDay: load,
    onChanged: (_) async {},
  ),
);

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _show(WidgetTester tester, Finder item) async {
  await tester.scrollUntilVisible(
    item,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  expect(item.hitTestable(), findsOneWidget);
}

Future<void> _chooseHistoryDay(WidgetTester tester, DateTime day) async {
  await tester.tap(find.widgetWithText(ChoiceChip, 'History'));
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(ReviewPage));
  final label = MaterialLocalizations.of(context).formatMediumDate(day);
  final row = find.widgetWithText(ListTile, label);
  await _show(tester, row);
  await tester.tap(row.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a legacy agenda may still supply synchronous free time', (
    tester,
  ) async {
    _viewport(tester, const Size(320, 568));
    await tester.pumpWidget(
      _app(
        agenda: ReviewAgenda(
          availability: [
            ReviewWindow(_today, _today.add(const Duration(minutes: 15))),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('15 min free'), findsOneWidget);
  });

  testWidgets(
    'pending, unknown, and failed availability leave the statistic hidden',
    (tester) async {
      _viewport(tester, const Size(320, 568));
      final pending = Completer<ReviewDayAvailability?>();
      var calls = 0;
      Future<ReviewDayAvailability?> load(DateTime day) {
        calls++;
        expect(day, _today);
        return pending.future;
      }

      final legacy = ReviewAgenda(
        availability: [
          ReviewWindow(_today, _today.add(const Duration(minutes: 45))),
        ],
      );
      await tester.pumpWidget(_app(load: load, agenda: legacy));
      await tester.pumpAndSettle();
      expect(find.textContaining(' free'), findsNothing);
      expect(find.text('Nothing due or scheduled.'), findsOneWidget);
      await tester.pumpWidget(_app(load: load, agenda: legacy));
      await tester.pumpAndSettle();
      expect(calls, 1);
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(find.textContaining(' free'), findsNothing);

      await tester.pumpWidget(
        _app(
          agenda: legacy,
          load: (_) {
            calls++;
            throw StateError('Calendar unavailable');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining(' free'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, direction) in [
    (const Size(320, 568), TextDirection.rtl),
    (const Size(568, 320), TextDirection.ltr),
  ]) {
    testWidgets(
      'only the selected day can display completed availability at $size and 200%',
      (tester) async {
        _viewport(tester, size);
        final pending = <DateTime, Completer<ReviewDayAvailability?>>{};
        final calls = <DateTime>[];
        Future<ReviewDayAvailability?> load(DateTime day) {
          calls.add(day);
          return pending
              .putIfAbsent(day, Completer<ReviewDayAvailability?>.new)
              .future;
        }

        final second = nextReviewDay(_today);
        final third = nextReviewDay(_today, 2);
        await tester.pumpWidget(
          _app(load: load, direction: direction, scale: 2),
        );
        await tester.pumpAndSettle();
        expect(calls, [_today]);

        pending[_today]!.complete(_knownAvailability(_today, 45));
        await tester.pumpAndSettle();
        await _show(tester, find.text('45 min free'));

        await _chooseHistoryDay(tester, second);
        expect(calls, [_today, second]);
        expect(find.textContaining(' free'), findsNothing);

        await _chooseHistoryDay(tester, third);
        expect(calls, [_today, second, third]);
        expect(find.textContaining(' free'), findsNothing);

        pending[third]!.complete(_knownAvailability(third, 0));
        await tester.pumpAndSettle();
        await _show(tester, find.text('0 min free'));
        pending[second]!.complete(_knownAvailability(second, 60));
        await tester.pumpAndSettle();
        expect(find.text('0 min free'), findsOneWidget);
        expect(find.text('1 h free'), findsNothing);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Habits'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Day'));
        await tester.pumpAndSettle();
        await _show(tester, find.text('0 min free'));
        expect(calls, [_today, second, third]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
