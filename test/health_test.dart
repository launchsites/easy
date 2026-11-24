import 'package:easy/health/health.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final day = DateTime(2026, 11, 24, 12);
  const bench = HealthExerciseTarget(
    planId: 'upper',
    exerciseId: 'bench',
    name: 'Bench press',
    planName: 'Upper body',
  );
  const row = HealthExerciseTarget(
    planId: 'upper',
    exerciseId: 'row',
    name: 'Cable row',
    planName: 'Upper body',
  );

  test(
    'weight and length preserve entered units and convert independently',
    () {
      final weight = BodyMeasurement(
        id: 'weight',
        kind: MeasurementKind.bodyWeight,
        unit: MeasurementUnit.pounds,
        value: 160,
        recordedAt: day,
      );
      final waist = BodyMeasurement(
        id: 'waist',
        kind: MeasurementKind.waist,
        unit: MeasurementUnit.inches,
        value: 30,
        recordedAt: day,
      );
      expect(
        weight.inUnit(MeasurementUnit.kilograms),
        closeTo(72.5747792, .00000001),
      );
      expect(
        waist.inUnit(MeasurementUnit.centimeters),
        closeTo(76.2, .00000001),
      );
      expect(
        () => waist.inUnit(MeasurementUnit.kilograms),
        throwsArgumentError,
      );
      expect(
        () => BodyMeasurement(
          id: 'bad',
          kind: MeasurementKind.waist,
          unit: MeasurementUnit.pounds,
          value: 160,
          recordedAt: day,
        ),
        throwsFormatException,
      );
      for (final invalid in [
        double.nan,
        double.infinity,
        0.0,
        -70.0,
        1.7e308,
      ]) {
        expect(
          () => BodyMeasurement(
            id: 'bad',
            kind: MeasurementKind.bodyWeight,
            unit: MeasurementUnit.kilograms,
            value: invalid,
            recordedAt: day,
          ),
          throwsFormatException,
        );
      }

      final original = HealthData(
        measurements: [weight, waist],
        goals: [
          MeasurementGoal(
            kind: MeasurementKind.bodyWeight,
            unit: MeasurementUnit.kilograms,
            value: 71.5,
          ),
        ],
      );
      final restored = HealthData.decode(original.encode());
      expect(restored.toJson(), original.toJson());
      expect(restored.measurements.first.unit, MeasurementUnit.pounds);
      expect(restored.measurements.first.value, 160);
    },
  );

  test(
    'passing a review date keeps the note open and exact plan scope intact',
    () {
      final note = HealthLimitation(
        id: 'recorded',
        title: 'Shoulder note',
        reportedOn: DateTime(2026, 11, 18),
        reviewOn: DateTime(2026, 11, 20),
        note: 'Reported during the warm-up.',
        exercises: const [bench],
      );
      final health = HealthData(limitations: [note]);
      expect(note.open, isTrue);
      expect(note.reviewIsDue(day), isTrue);
      expect(
        health.forWorkout(
          planId: 'upper',
          exerciseIds: ['bench'],
          workoutAt: day,
        ),
        [note],
      );
      expect(
        health.forWorkout(
          planId: 'other-plan',
          exerciseIds: ['bench'],
          workoutAt: day,
        ),
        isEmpty,
      );
      expect(
        health.forWorkout(
          planId: 'upper',
          exerciseIds: ['row'],
          workoutAt: day,
        ),
        isEmpty,
      );

      final resolved = note.withReview(
        HealthLimitationReview(
          reviewedAt: day,
          outcome: HealthReviewOutcome.resolved,
          note: 'User resolved this note.',
        ),
      );
      final reopened = HealthData.decode(
        health.withLimitation(resolved).encode(),
      );
      final stored = reopened.limitations.single;
      expect(stored.note, note.note);
      expect(stored.open, isFalse);
      expect(stored.reviews.single.note, 'User resolved this note.');
      expect(
        reopened.forWorkout(
          planId: 'upper',
          exerciseIds: ['bench'],
          workoutAt: day,
        ),
        isEmpty,
      );
      expect(
        reopened.forWorkout(
          planId: 'upper',
          exerciseIds: ['bench'],
          workoutAt: day.subtract(const Duration(hours: 1)),
        ),
        [stored],
      );
    },
  );

  test(
    'workout decisions preserve exact exercise and note IDs independently',
    () {
      final choice = WorkoutHealthDecision(
        planId: 'upper',
        workoutAt: day,
        reviewedAt: day,
        reviewedNoteIds: const ['user-note'],
        skippedExerciseIds: const ['bench'],
      );
      final data = HealthData().withWorkoutDecision(choice);
      expect(() => data.withWorkoutDecision(choice), throwsFormatException);
      final reopened = HealthData.decode(data.encode());
      expect(reopened.decisions.single.reviewedNoteIds, {'user-note'});
      expect(reopened.decisions.single.skippedExerciseIds, {'bench'});
      expect(reopened.decisions.single.planId, 'upper');
    },
  );

  testWidgets(
    'a compact measurement form handles retry and display conversion',
    (tester) async {
      _phone(tester);
      HealthData? saved;
      var fail = true;
      await tester.pumpWidget(
        _app(
          HealthPage(
            data: HealthData(),
            clock: () => day,
            onChanged: (data) async {
              if (fail) throw StateError('retry needed');
              saved = data;
            },
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Log measurement'));
      await tester.pumpAndSettle();
      final number = find.widgetWithText(TextField, 'Value');
      await tester.enterText(number, '73.25');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('The measurement could not be saved.'), findsOneWidget);
      expect(tester.widget<TextField>(number).controller!.text, '73.25');
      fail = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(saved?.measurements.single.value, 73.25);
      expect(find.text('73.25 kg'), findsOneWidget);
      await tester.tap(find.byTooltip('Display unit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lb').last);
      await tester.pumpAndSettle();
      expect(find.text('161.49 lb'), findsOneWidget);
      expect(saved?.measurements.single.unit, MeasurementUnit.kilograms);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a workout review can be cancelled or explicitly skip one matching exercise',
    (tester) async {
      _phone(tester);
      final data = HealthData(
        limitations: [
          HealthLimitation(
            id: 'bench-note',
            title: 'Shoulder note',
            reportedOn: day,
            exercises: const [bench],
          ),
        ],
      );
      final decisions = <WorkoutHealthDecision?>[];
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async => decisions.add(
                  await showWorkoutHealthReview(
                    context,
                    data: data,
                    planId: 'upper',
                    exercises: const [bench, row],
                    workoutAt: day,
                    clock: () => day,
                  ),
                ),
                child: const Text('Review this plan'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review this plan'));
      await tester.pumpAndSettle();
      expect(find.text('Shoulder note'), findsOneWidget);
      expect(find.widgetWithText(CheckboxListTile, row.name), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, bench.name),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(decisions.single, isNull);
      await tester.tap(find.text('Review this plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bench press'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with skips'));
      await tester.pumpAndSettle();
      final approved = decisions.last!;
      expect(approved.reviewedNoteIds, {'bench-note'});
      expect(approved.skippedExerciseIds, {'bench'});
      expect(data.limitations.single.open, isTrue);
      expect(data.decisions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workout note settings preserve the authored note when explicitly resolved',
    (tester) async {
      _phone(tester);
      var saved = HealthData(
        limitations: [
          HealthLimitation(
            id: 'local-note',
            title: 'Knee note',
            reportedOn: DateTime(2026, 11, 22),
            reviewOn: DateTime(2026, 11, 23),
            note: 'Recorded after the hill session.',
            allWorkouts: true,
          ),
        ],
      );
      await tester.pumpWidget(
        _app(
          HealthPage(
            data: saved,
            clock: () => day,
            exerciseTargets: const [bench, row],
            onChanged: (data) async => saved = data,
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Workout notes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Review due'), findsOneWidget);
      await tester.tap(find.text('Knee note'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add review'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Review note'),
        'Explicitly resolved after review.',
      );
      await tester.tap(find.text('Resolve note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save review'));
      await tester.pumpAndSettle();
      expect(saved.limitations.single.open, isFalse);
      expect(saved.limitations.single.note, 'Recorded after the hill session.');
      expect(
        saved.limitations.single.reviews.single.note,
        'Explicitly resolved after review.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _app(Widget home) => MaterialApp(theme: easyTheme(), home: home);
