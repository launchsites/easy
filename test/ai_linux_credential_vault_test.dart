import 'package:easy/ai/ai_linux_credential_vault.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _reference = 'easy.ai.${'a' * 64}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('easy.test/linux-ai-credentials');
  const vault = AiLinuxCredentialVault(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'a native service error remains an unsuccessful credential access',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'available') return false;
        throw PlatformException(code: 'credentialServiceUnavailable');
      });
      expect(await vault.available(), isFalse);
      await expectLater(
        vault.read(_reference),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        vault.write(_reference, 'Synthetic-test-key'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        vault.delete(_reference),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'invalid input is rejected before it reaches the native channel',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async => calls++);
      expect(() => vault.read('$_reference\n'), throwsFormatException);
      expect(() => vault.delete('workspace-key'), throwsFormatException);
      await expectLater(
        vault.write(_reference, 'with a space'),
        throwsFormatException,
      );
      await expectLater(
        vault.write(_reference, 'x' * 4097),
        throwsFormatException,
      );
      expect(calls, 0);
    },
  );

  test('credentials are addressed by the intact provider reference and write is verified', () async {
    final keys = <String, String>{};
    final operations = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      operations.add(call.method);
      if (call.method == 'available') return true;
      final arguments = call.arguments as Map;
      final reference = arguments['reference'] as String;
      switch (call.method) {
        case 'read':
          return keys[reference];
        case 'write':
          keys[reference] = arguments['secret'] as String;
          return null;
        case 'delete':
          keys.remove(reference);
          return null;
      }
      throw MissingPluginException();
    });
    expect(await vault.available(), isTrue);
    await vault.write(_reference, 'Synthetic-test-key');
    expect(operations, ['available', 'write', 'read']);
    expect(await vault.read(_reference), 'Synthetic-test-key');
    expect(await vault.read('easy.ai.${'b' * 64}'), isNull);
    await vault.delete(_reference);
    expect(await vault.read(_reference), isNull);

    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await expectLater(
      vault.write(_reference, 'Synthetic-test-key'),
      throwsStateError,
    );
  });
}
