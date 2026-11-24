import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/availability_settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('weekly hours are a draft until the explicit review is saved', (
    tester,
  ) async {
    SchedulingSettings? result;
    final original = SchedulingSettings();
    await tester.pumpWidget(_host(original, (value) => result = value));
    await tester.tap(find.text('Open scheduling'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add hours'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Mon'));
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Work'));
    await tester.tap(find.widgetWithText(FilterChip, 'Work'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(original.availability, isEmpty);

    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.text('Review scheduling settings'), findsOneWidget);
    expect(find.textContaining('Mon ·'), findsWidgets);
    expect(result, isNull);
    await tester.tap(find.text('Back to editing'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save settings'));
    await tester.pumpAndSettle();
    expect(result?.availability.single.weekdays, {DateTime.monday});
    expect(result?.availability.single.categories, {'work'});
  });

  testWidgets(
    'routes and buffers fit a small viewport and abandoning edits preserves settings',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var returned = false;
      final original = SchedulingSettings(
        places: [
          SavedPlace(id: 'a', name: 'Campus', privateDetail: 'Local record'),
          SavedPlace(id: 'b', name: 'Library'),
        ],
        routes: [TravelDuration(fromPlaceId: 'a', toPlaceId: 'b', minutes: 25)],
      );
      await tester.pumpWidget(
        _host(original, (value) {
          expect(value, isNull);
          returned = true;
        }, textScale: 1.4),
      );
      await tester.tap(find.text('Open scheduling'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Places & travel'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Campus → Library'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.textContaining('Campus → Library'));
      await tester.pumpAndSettle();
      expect(find.text('Travel duration'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '36');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.textContaining('36 min'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(original.routes.single.minutes, 25);
    },
  );
}

Widget _host(
  SchedulingSettings settings,
  ValueChanged<SchedulingSettings?> onResult, {
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        child: const Text('Open scheduling'),
        onPressed: () async => onResult(
          await showSchedulingSettingsEditor(
            context,
            settings: settings,
            categories: const {'work': 'Work', 'study': 'Study'},
          ),
        ),
      ),
    ),
  ),
);
