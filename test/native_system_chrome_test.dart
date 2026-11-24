import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('system bars follow the active phone or wide work surface', (
    tester,
  ) async {
    final preferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = preferences);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
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

    await tester.pumpWidget(
      const EasyApp(openStore: openPreferenceWorkspaceStore),
    );
    await tester.pumpAndSettle();
    expect(published.last['statusBarIconBrightness'], 'Brightness.dark');
    expect(
      published.last['systemNavigationBarIconBrightness'],
      'Brightness.dark',
    );
    expect(published.last['statusBarBrightness'], 'Brightness.light');

    tester.view.physicalSize = const Size(1040, 820);
    await tester.pumpAndSettle();
    expect(published.last['statusBarIconBrightness'], 'Brightness.light');
    expect(
      published.last['systemNavigationBarIconBrightness'],
      'Brightness.light',
    );
    expect(published.last['statusBarBrightness'], 'Brightness.dark');
    expect(tester.takeException(), isNull);
  });
}
