import 'package:easy/main.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/onboarding/workspace_setup.dart';
import 'package:easy/preferences/feature_preferences.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final samples in [false, true]) {
    testWidgets(
      'Initial workspace saves ${samples ? 'chosen samples' : 'blank Skip'} once',
      (tester) async {
        final previous = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        Future<WorkspaceSnapshot> seed() async => WorkspaceSnapshot(
          workspaceJson: WorkspaceData(
            events: [],
            tasks: [],
            notes: [],
            sections: const {'workspaceSetup': 'pending'},
          ).encode(),
          gymSessionJson: const [],
          workoutPlanJson: const [],
        );

        Future<WorkspaceStore> open({
          required SharedPreferencesAsync preferences,
          required Future<WorkspaceSnapshot> Function() readLegacy,
        }) => openPreferenceWorkspaceStore(
          preferences: preferences,
          readLegacy: seed,
        );

        Future<void> tap(String label) async {
          final item = find.text(label);
          await tester.ensureVisible(item);
          await tester.pumpAndSettle();
          await tester.tap(item.hitTestable());
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(EasyApp(openStore: open));
        await tester.pumpAndSettle();
        expect(find.byType(WorkspaceSetupPage), findsOneWidget);
        if (samples) await tap('Full');
        await tap(samples ? 'Explore with samples' : 'Skip');
        expect(find.byType(WorkspaceSetupPage), findsNothing);
        expect(find.byType(MobileHome), findsOneWidget);

        final store = await open(
          preferences: SharedPreferencesAsync(),
          readLegacy: seed,
        );
        final finished = await store.read();
        final data = WorkspaceData.decode(finished.snapshot.workspaceJson);
        expect(finished.revision, 2);
        expect(data.sections['workspaceSetup'], 'complete');
        final features = FeaturePreferences.fromJson(
          data.sections['features']! as Map<String, Object?>,
        );
        expect(features.allows(EasyFeature.workouts), samples);
        expect(data.tasks.isNotEmpty, samples);
        expect(finished.snapshot.workoutPlanJson.isNotEmpty, samples);
        await store.close();

        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(EasyApp(openStore: open));
        await tester.pumpAndSettle();
        expect(find.byType(WorkspaceSetupPage), findsNothing);
        expect(find.byType(MobileHome), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
