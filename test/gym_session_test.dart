import 'package:easy/gym_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Planned work, adjusted actuals, and extras stay chronological', (
    tester,
  ) async {
    _phoneViewport(tester);
    GymSession? snapshot;
    await tester.pumpWidget(
      MaterialApp(
        home: GymSessionPage(
          session: null,
          onChanged: (session) => snapshot = session,
        ),
      ),
    );
    await tester.tap(find.text('Planned session'));
    await tester.pumpAndSettle();
    expect(find.text('0.5 km · 5 min · 2% incline'), findsOneWidget);
    expect(find.text('50 kg × 8, 8, 8'), findsOneWidget);

    await tester.tap(find.text('Log as planned').first);
    await tester.pumpAndSettle();
    expect(snapshot!.entries.single.actual, '0.5 km · 5 min · 2% incline');
    expect(find.byTooltip('Enter actual for Treadmill'), findsNothing);

    await _typeAndLog(tester, 'Stretch');
    final bench = find.byTooltip('Enter actual for Bench press');
    await tester.ensureVisible(bench);
    await tester.tap(bench);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 245);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await _typeAndLog(tester, '55 kg × 8, 8, 6');
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();

    expect(snapshot!.entries.map((entry) => entry.title), [
      'Treadmill',
      'Stretch',
      'Bench press',
    ]);
    expect(find.text('Plan'), findsNothing);
    expect(snapshot!.entries.last.actual, '55 kg × 8, 8, 6');
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(snapshot!.finished, true);
    final restored = GymSession.decode(snapshot!.encode());
    expect(restored.finished, true);
    expect(restored.startedAt, snapshot!.startedAt);
    expect(restored.entries.last.actual, '55 kg × 8, 8, 6');
    expect(find.text('Session complete'), findsOneWidget);
  });

  testWidgets('A saved freestyle session resumes with its existing results', (
    tester,
  ) async {
    _phoneViewport(tester);
    GymSession? snapshot;
    Widget workspace(GymSession? session) => MaterialApp(
      home: GymSessionPage(
        session: session,
        onChanged: (updated) => snapshot = updated,
      ),
    );
    await tester.pumpWidget(workspace(null));
    await tester.tap(find.text('Freestyle'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsNothing);
    await _typeAndLog(tester, 'Stretch');
    final restored = GymSession.decode(snapshot!.encode());

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(workspace(restored));
    await tester.pumpAndSettle();
    expect(find.text('Stretch'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
    await _typeAndLog(tester, 'Walk 10 minutes');
    expect(snapshot!.startedAt, restored.startedAt);
    expect(snapshot!.entries.map((entry) => entry.title), [
      'Stretch',
      'Walk 10 minutes',
    ]);
  });
}

void _phoneViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _typeAndLog(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}
