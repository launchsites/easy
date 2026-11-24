import 'package:easy/appearance/system_inset_background.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('system bars follow the phone and wide surfaces on $platform', (
      tester,
    ) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
      final preferences = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = preferences);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPhysicalSize);

      final published = <Map<Object?, Object?>>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
          published.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
      await tester.pump();
      published.clear();

      await tester.pumpWidget(
        const EasyApp(openStore: openPreferenceWorkspaceStore),
      );
      await tester.pumpAndSettle();
      final android = platform == TargetPlatform.android;
      final icons = android ? 'Brightness.light' : 'Brightness.dark';
      expect(published.last['statusBarIconBrightness'], icons);
      expect(
        published.last['systemNavigationBarIconBrightness'],
        android ? icons : null,
      );
      expect(
        published.last['statusBarBrightness'],
        android ? 'Brightness.dark' : 'Brightness.light',
      );
      final background = find.byType(SystemInsetBackground);
      expect(background, android ? findsOneWidget : findsNothing);
      if (android) expect(tester.getSize(background), const Size(390, 844));

      tester.view.physicalSize = const Size(1040, 820);
      await tester.pumpAndSettle();
      expect(published.last['statusBarIconBrightness'], 'Brightness.light');
      expect(
        published.last['systemNavigationBarIconBrightness'],
        android ? 'Brightness.light' : null,
      );
      expect(published.last['statusBarBrightness'], 'Brightness.dark');
      expect(tester.takeException(), isNull);
    });
  }
}
