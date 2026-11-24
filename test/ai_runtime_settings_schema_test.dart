import 'package:easy/ai/ai_runtime_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('older local settings keep plain capture replies', () {
    final values = const AiRuntimeSettings(
      route: AiRoute.local,
      localModel: 'fixture-local',
    ).toJson()..remove('localCaptureJsonSchema');
    final restored = AiRuntimeSettings.fromJson(values);
    expect(restored.valid, isTrue);
    expect(restored.localCaptureJsonSchema, isFalse);
    expect(restored.provider!.captureJsonSchema, isFalse);
  });

  test(
    'explicit capability round-trips and stays confined to local capture',
    () {
      final values = const AiRuntimeSettings(
        route: AiRoute.local,
        localModel: 'fixture-local',
        localCaptureJsonSchema: true,
        apiBaseUrl: 'https://provider.example/v1',
        apiModel: 'fixture-api',
        inputMicrosPerMillion: 1000,
        outputMicrosPerMillion: 1000,
        monthlyCapMicros: 1000000,
      ).toJson();
      final local = AiRuntimeSettings.fromJson(values);
      expect(local.provider!.captureJsonSchema, isTrue);
      final paid = AiRuntimeSettings.fromJson({...values, 'route': 'api'});
      expect(paid.provider!.captureJsonSchema, isFalse);
      expect(paid.localCaptureJsonSchema, isTrue);
    },
  );
}
