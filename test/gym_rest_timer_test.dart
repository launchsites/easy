import 'package:easy/gym_rest_timer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('rest ends by its saved deadline across app suspension', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 24, 9);
    DateTime? endsAt;
    var started = 0;
    var cleared = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) => Scaffold(
            body: Center(
              child: GymRestTimer(
                endsAt: endsAt,
                onStart: (value) => update(() {
                  started++;
                  endsAt = now.add(value);
                }),
                onClear: () => update(() {
                  cleared++;
                  endsAt = null;
                }),
                clock: () => now,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Rest timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 sec'));
    await tester.pumpAndSettle();
    expect(endsAt, DateTime.utc(2026, 11, 24, 9, 0, 30));
    expect(find.text('0:30'), findsOneWidget);

    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:28'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(started, 1);
    expect(cleared, 0);

    await tester.tap(find.byTooltip('Rest timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear timer'));
    await tester.pumpAndSettle();
    expect(endsAt, isNull);
    expect(cleared, 1);
  });
}
