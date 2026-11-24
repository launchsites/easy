import 'package:easy/focus/focus_mode.dart';
import 'package:easy/focus/focus_modes_page.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _categories = {
  'work': 'Work',
  'study': 'Study',
  'gym': 'Gym',
  'health': 'Health',
};

void main() {
  testWidgets('creates a mode with independent display and capture choices', (
    tester,
  ) async {
    List<FocusMode>? updated;
    await _show(tester, const [], (modes) => updated = modes);
    await _tap(tester, find.text('New mode'));
    await _tap(tester, find.text('Save mode'));
    expect(find.text('Enter a mode name.'), findsOneWidget);
    expect(updated, isNull);

    await tester.enterText(find.byType(TextFormField), 'Deep work');
    await _tap(tester, find.byTooltip('Blue'));
    await _tap(tester, find.text('All categories'));
    await _tap(tester, find.widgetWithText(FilterChip, 'Study'));
    await _tap(tester, find.widgetWithText(FilterChip, 'Workout'));
    await _tap(tester, find.widgetWithText(FilterChip, 'Nutrition'));
    final captureCategory = find.byType(DropdownButtonFormField<String>);
    await _tap(tester, captureCategory);
    await _tap(tester, find.text('Work').last);
    await _tap(tester, find.text('Save mode'));

    expect(find.text('Deep work'), findsOneWidget);
    final mode = updated!.single;
    expect(mode.name, 'Deep work');
    expect(mode.color, 0xff4e6c9b);
    expect(mode.categories, {'study'});
    expect(mode.preferredCategory, 'work');
    expect(mode.sections, {
      FocusSection.schedule,
      FocusSection.tasks,
      FocusSection.workout,
      FocusSection.nutrition,
    });
    expect(() => updated!.clear(), throwsUnsupportedError);
  });

  testWidgets('edits and removes only the chosen view at large text size', (
    tester,
  ) async {
    final gym = FocusMode(
      id: 'gym-view',
      name: 'Training',
      color: 0xff896753,
      categories: {'archived category'},
      sections: {FocusSection.workout},
      preferredCategory: 'work',
    );
    final study = standardFocusModes().firstWhere((mode) => mode.id == 'study');
    final original = [gym, study];
    List<FocusMode>? updated;
    await _show(
      tester,
      original,
      (modes) => updated = modes,
      size: const Size(320, 568),
      textScale: 1.75,
    );

    await _tap(tester, find.text('Training'));
    await tester.enterText(find.byType(TextFormField), 'Morning workout');
    await _tap(tester, find.byTooltip('Blue'));
    await _tap(tester, find.byTooltip('Custom color'));
    expect(
      find.widgetWithText(FilterChip, 'archived category'),
      findsOneWidget,
    );
    await _tap(tester, find.text('All categories'));
    await _tap(tester, find.byType(DropdownButtonFormField<String>));
    await _tap(tester, find.text('No preference').last);
    await _tap(tester, find.text('Save mode'));

    final edited = updated!.first;
    expect(edited.id, gym.id);
    expect(edited.name, 'Morning workout');
    expect(edited.categories, isNull);
    expect(edited.preferredCategory, isNull);
    expect(edited.color, gym.color);
    expect(updated!.last, same(study));
    expect(tester.takeException(), isNull);

    await _tap(tester, find.text('Morning workout'));
    await _tap(tester, find.text('Delete mode'));
    expect(find.text('Remove this view from the mode menu.'), findsOneWidget);
    await _tap(tester, find.text('Cancel'));
    expect(find.text('Edit focus mode'), findsOneWidget);
    await _tap(tester, find.text('Delete mode'));
    await _tap(tester, find.widgetWithText(FilledButton, 'Delete mode'));

    expect(updated, [study]);
    expect(original, [gym, study]);
    expect(find.text('Morning workout'), findsNothing);
    expect(find.text('Study'), findsOneWidget);
  });
}

Future<void> _show(
  WidgetTester tester,
  List<FocusMode> modes,
  ValueChanged<List<FocusMode>> onChanged, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: FocusModesPage(
        modes: modes,
        categories: _categories,
        onChanged: onChanged,
      ),
    ),
  );
}

Future<void> _tap(WidgetTester tester, Finder control) async {
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}
