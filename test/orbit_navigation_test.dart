import 'package:easy/orbit_navigation.dart';
import 'package:easy/ui_theme.dart' show accent, easyTheme;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _destinations = [
  OrbitDestination('Today', Icons.today_outlined),
  OrbitDestination('Calendar', Icons.calendar_month_outlined),
  OrbitDestination('Tasks', Icons.check_box_outlined),
  OrbitDestination('Notes', Icons.description_outlined),
];

final _launcher = find.byTooltip('Navigate');

Future<void> _mount(
  WidgetTester tester,
  List<int> selections, {
  VoidCallback? onAdd,
  Size surface = const Size(390, 844),
  double bottomPadding = 0,
  bool reduceMotion = false,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: EdgeInsets.only(bottom: bottomPadding),
          reduceMotion: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (onAdd != null)
              Positioned(
                right: 20,
                bottom: 20,
                child: IconButton(
                  onPressed: onAdd,
                  tooltip: 'Add',
                  icon: const Icon(Icons.add),
                ),
              ),
            OrbitNavigation(
              destinations: _destinations,
              selectedIndex: 0,
              onSelected: selections.add,
            ),
          ],
        ),
      ),
    ),
  );
}

Future<TestGesture> _holdLauncher(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(_launcher));
  await tester.pump(const Duration(milliseconds: 340));
  return gesture;
}

void main() {
  testWidgets('tap opens destinations for direct selection', (tester) async {
    final selections = <int>[];
    await _mount(tester, selections);

    await tester.tap(_launcher);
    await tester.pumpAndSettle();
    for (final destination in _destinations) {
      expect(find.text(destination.label), findsOneWidget);
    }

    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();

    expect(selections, [1]);
    expect(find.text('Calendar'), findsNothing);
  });

  testWidgets('hold and drag previews a destination until release', (
    tester,
  ) async {
    final selections = <int>[];
    await _mount(tester, selections);

    final gesture = await _holdLauncher(tester);
    final tasks = find.widgetWithText(TextButton, 'Tasks');
    await gesture.moveTo(tester.getCenter(tasks));
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(tasks);
    expect(button.style?.backgroundColor?.resolve({}), accent);
    expect(selections, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(selections, [2]);
    expect(tasks, findsNothing);
  });

  testWidgets('return to the launcher before release cancels the drag', (
    tester,
  ) async {
    final selections = <int>[];
    await _mount(tester, selections);
    final center = tester.getCenter(_launcher);

    final gesture = await _holdLauncher(tester);
    await gesture.moveTo(tester.getCenter(find.text('Notes')));
    await tester.pump();
    await gesture.moveTo(center);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selections, isEmpty);
    expect(find.text('Notes'), findsNothing);
  });

  testWidgets('pointer cancellation clears the menu without navigating', (
    tester,
  ) async {
    final selections = <int>[];
    await _mount(tester, selections);

    final gesture = await _holdLauncher(tester);
    await gesture.moveTo(tester.getCenter(find.text('Today')));
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(selections, isEmpty);
    expect(find.text('Today'), findsNothing);
  });

  testWidgets('dismisses outside and allows the other control once closed', (
    tester,
  ) async {
    final selections = <int>[];
    var addCount = 0;
    await _mount(tester, selections, onAdd: () => addCount++);

    await tester.tap(_launcher);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(260, 350));
    await tester.pumpAndSettle();
    expect(find.text('Calendar'), findsNothing);

    await tester.tap(find.byTooltip('Add'));

    expect(addCount, 1);
    expect(selections, isEmpty);
  });

  testWidgets('keyboard can open, choose and dismiss the menu', (tester) async {
    final selections = <int>[];
    await _mount(tester, selections);
    final launcher = tester.widget<IconButton>(find.byType(IconButton));
    launcher.focusNode!.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selections, [1]);
    expect(launcher.focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Calendar'), findsNothing);
    expect(launcher.focusNode!.hasFocus, isTrue);
  });

  testWidgets('system back dismisses the expanded menu', (tester) async {
    final selections = <int>[];
    await _mount(tester, selections);
    await tester.tap(_launcher);
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Calendar'), findsNothing);
    expect(selections, isEmpty);
  });

  testWidgets(
    'every destination is reachable on a narrow phone with safe area',
    (tester) async {
      final selections = <int>[];
      const surface = Size(320, 568);
      await _mount(
        tester,
        selections,
        surface: surface,
        bottomPadding: 34,
        reduceMotion: true,
      );

      expect(tester.getRect(_launcher).bottom, surface.height - 34 - 20);

      for (final (index, destination) in _destinations.indexed) {
        final gesture = await _holdLauncher(tester);
        final button = find.widgetWithText(TextButton, destination.label);
        final bounds = tester.getRect(button);
        expect(bounds.width, closeTo(56, .001));
        expect(bounds.height, closeTo(56, .001));
        expect((Offset.zero & surface).contains(bounds.topLeft), isTrue);
        expect((Offset.zero & surface).contains(bounds.bottomRight), isTrue);

        await gesture.moveTo(bounds.center);
        await gesture.up();
        await tester.pumpAndSettle();

        expect(selections.last, index);
        expect(button, findsNothing);
      }
    },
  );

  testWidgets(
    'large text offers full tap labels and preserves drag selection',
    (tester) async {
      final selections = <int>[];
      await _mount(
        tester,
        selections,
        surface: const Size(320, 568),
        textScale: 2,
      );
      await tester.tap(_launcher);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Calendar'), findsOneWidget);
      await tester.tap(find.text('Calendar'));
      await tester.pumpAndSettle();
      expect(selections, [1]);

      final gesture = await _holdLauncher(tester);
      final tasks = find.bySemanticsLabel('Tasks');
      expect(tasks, findsOneWidget);
      expect(find.text('Tasks'), findsNothing);
      await gesture.moveTo(tester.getCenter(tasks));
      await tester.pump();
      expect(find.text('Tasks'), findsOneWidget);
      expect(selections, [1]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selections, [1, 2]);
    },
  );

  testWidgets('platform reduced motion skips the orbit reveal animation', (
    tester,
  ) async {
    final selections = <int>[];
    await _mount(tester, selections, reduceMotion: true);
    await tester.tap(_launcher);
    await tester.pump();

    final animations = tester.widgetList<TweenAnimationBuilder<double>>(
      find.byType(TweenAnimationBuilder<double>),
    );
    expect(animations, hasLength(_destinations.length));
    expect(
      animations.map((animation) => animation.duration),
      everyElement(Duration.zero),
    );
  });

  testWidgets('the orbit fits landscape and a short body', (tester) async {
    for (final (surface, targetSize) in [
      (const Size(640, 320), 60.0),
      (const Size(320, 205), 48.0),
    ]) {
      final selections = <int>[];
      await _mount(tester, selections, surface: surface);
      await tester.tap(_launcher);
      await tester.pumpAndSettle();

      for (final destination in _destinations) {
        final button = find.widgetWithText(TextButton, destination.label);
        final bounds = tester.getRect(button);
        expect(bounds.width, closeTo(targetSize, .001));
        expect(bounds.height, closeTo(targetSize, .001));
        expect((Offset.zero & surface).contains(bounds.topLeft), isTrue);
        expect((Offset.zero & surface).contains(bounds.bottomRight), isTrue);
      }

      await tester.tap(find.text('Notes'));
      await tester.pumpAndSettle();
      expect(selections, [3]);
    }
  });
}
