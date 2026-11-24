import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/ai_runtime.dart';
import 'package:easy/ai/vision/meal_vision.dart';
import 'package:easy/ai/vision/vision_image.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:easy/nutrition/meal_vision_review.dart';
import 'package:easy/nutrition/nutrition_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('re-encodes a bounded derivative without PNG source metadata', () async {
    final source = await _photo();
    final image = await prepareAiVisionImage(source);
    expect(latin1.decode(source), contains(_privateMarker));
    expect(latin1.decode(image.bytes), isNot(contains(_privateMarker)));
    expect(_pngTypes(image.bytes), containsAll(['IHDR', 'IDAT', 'IEND']));
    expect(
      _pngTypes(image.bytes),
      everyElement(isIn(['IHDR', 'IDAT', 'IEND'])),
    );
    expect(image.width, AiVisionImage.maxEdge);
    expect(image.height, AiVisionImage.maxEdge ~/ 2);
    expect(image.bytes.length, lessThanOrEqualTo(AiVisionImage.maxBytes));
    expect(() => image.bytes[0] = 1, throwsUnsupportedError);
    await expectLater(
      prepareAiVisionImage(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<AiVisionImageException>()),
    );
  });

  test('rejects stale, fabricated, duplicated and malformed suggestions', () {
    const valid = {'label': 'Café au lait', 'grams': null};
    expect(
      validateMealVisionResponse(
        _result('this', [valid]),
        'this',
      )!.candidates.single.grams,
      isNull,
    );
    expect(
      validateMealVisionResponse(_result('before', [valid]), 'this'),
      isNull,
    );
    for (final entries in [
      [
        {...valid, 'energyKcal': 150},
      ],
      [
        {...valid, 'foodId': 'local-id'},
      ],
      [
        {...valid, 'label': 'Rice\u202e'},
      ],
      [
        valid,
        {...valid, 'label': '  CAFÉ AU   LAIT'},
      ],
      [
        {
          ...valid,
          'grams': {'minimum': 120, 'maximum': 80},
        },
      ],
      [
        {
          ...valid,
          'grams': {'minimum': 0, 'maximum': 80},
        },
      ],
      [
        {
          ...valid,
          'grams': {'minimum': 80},
        },
      ],
      [
        {
          ...valid,
          'grams': {'minimum': '80', 'maximum': 120},
        },
      ],
      List.generate(13, (index) => {'label': 'Candidate $index'}),
    ]) {
      expect(
        validateMealVisionResponse(_result('this', entries), 'this'),
        isNull,
        reason: '$entries',
      );
    }
  });

  test(
    'derives ranged nutrition from exact local foods and marks unknowns',
    () {
      final review = MealVisionReview([
        const MealVisionCandidate(label: 'brown  rice', grams: _interval),
        const MealVisionCandidate(label: 'Soup'),
        const MealVisionCandidate(label: 'Milk', grams: _interval),
        const MealVisionCandidate(label: 'Beans', grams: _interval),
        const MealVisionCandidate(label: 'Rice pudding', grams: _interval),
      ]);
      final rice = _food('rice', 'Brown Rice');
      final matches = matchMealVisionFoods(review, [
        rice,
        _food('soup', 'Soup'),
        _food('milk', 'Milk', unit: NutritionUnit.millilitres),
        _food('bean1', 'Beans'),
        _food('bean2', 'beans'),
      ]);
      expect(matches.map((match) => match.issue), [
        null,
        MealVisionMatchIssue.portionUnknown,
        MealVisionMatchIssue.incompatibleFood,
        MealVisionMatchIssue.foodAmbiguous,
        MealVisionMatchIssue.foodMissing,
      ]);
      expect(matches.first.portion!.food, same(rice));
      expect(matches.first.portion!.amount, 100);
      final totals = mealVisionNutritionTotals(matches);
      final energy = totals[Nutrient.energy]!;
      expect(energy.amount, 130);
      expect(energy.minimum, closeTo(104, 0.001));
      expect(energy.maximum, closeTo(156, 0.001));
      expect(energy.partial, true);
      expect(energy.estimated, true);
      expect(totals[Nutrient.protein]!.amount, isNull);
      final unknown = mealVisionNutritionTotals(
        matches.skip(1),
      )[Nutrient.energy]!;
      expect(unknown.amount, isNull);
      expect(unknown.partial, true);
    },
  );

  test(
    'loopback requires per-image consent and fences changed sources',
    () async {
      final image = await prepareAiVisionImage(await _photo());
      var requests = 0;
      var consented = false;
      final store = _Store((request) async {
        requests++;
        expect(consented, true);
        expect(request.url.host, '127.0.0.1');
        expect(request.headers['authorization'], isNull);
        return _answer(request, image);
      });
      addTearDown(store.dispose);
      final runtime = store.runtime;
      const local = AiRuntimeSettings(
        route: AiRoute.local,
        localModel: 'image-fixture',
        confirmLocal: false,
        allowMealVision: true,
      );
      expect(await runtime.saveSettings(local), AiSettingsSaveStatus.saved);
      expect(runtime.canRunMealVision, true);

      final declined = await runtime.runMealVision(
        source: _source(),
        image: image,
        currentRevision: _current,
        authorize: (preview) async {
          expect(preview.image, same(image));
          expect(preview.model, 'image-fixture');
          expect(preview.reserveMicros, isNull);
          expect(requests, 0);
          return false;
        },
      );
      expect(declined.status, AiRunStatus.declined);
      var current = true;
      final stale = await runtime.runMealVision(
        source: _source(),
        image: image,
        currentRevision: (id) => current ? _current(id) : null,
        authorize: (_) async {
          current = false;
          return true;
        },
      );
      expect(stale.status, AiRunStatus.stale);
      expect(requests, 0);
      final reviewed = await runtime.runMealVision(
        source: _source(),
        image: image,
        currentRevision: _current,
        authorize: (_) async => consented = true,
      );
      expect(reviewed.status, AiRunStatus.ready);
      expect(reviewed.source, AiRoute.local);
      expect(reviewed.value!.requiresReview, true);
      expect(reviewed.value!.candidates.single.label, 'Brown Rice');
      expect(requests, 1);

      await runtime.saveSettings(const AiRuntimeSettings());
      expect(runtime.canRunMealVision, false);
      final blocked = await runtime.runMealVision(
        source: _source(),
        image: image,
        currentRevision: _current,
        authorize: (_) => fail('Disabled vision cannot request consent.'),
      );
      expect(blocked.status, AiRunStatus.blocked);
      expect(requests, 1);
    },
  );

  test(
    'paid vision gates image tokens and durably reserves before sending',
    () async {
      final image = await prepareAiVisionImage(await _photo());
      int? maximum;
      var requests = 0;
      late final _Store store;
      store = _Store((request) async {
        requests++;
        expect(request.url.host, 'vision.example.test');
        expect(request.headers['authorization'], 'Bearer $_key');
        expect(maximum, isPositive);
        expect(store.ledger.report().reservedMicros, maximum);
        return _answer(request, image, usage: true);
      });
      addTearDown(store.dispose);
      final runtime = store.runtime;
      expect(_paid(imageTokens: null).valid, false);
      expect(_paid(imageTokens: 8192).valid, false);
      expect(
        await runtime.saveSettings(_paid(imageTokens: 8100), apiKey: _key),
        AiSettingsSaveStatus.saved,
      );
      final tooSmall = await runtime.runMealVision(
        source: _source(),
        image: image,
        currentRevision: _current,
        authorize: (_) => fail('Check token limits before the consent step.'),
      );
      expect(tooSmall.status, AiRunStatus.blocked);
      expect(requests, 0);
      expect(await runtime.saveSettings(_paid()), AiSettingsSaveStatus.saved);
      final reviewed = await runtime.runMealVision(
        source: _source(),
        image: image,
        currentRevision: _current,
        authorize: (preview) async {
          expect(preview.image, same(image));
          expect(store.ledger.report().reservedMicros, 0);
          maximum = preview.reserveMicros;
          return true;
        },
      );
      expect(reviewed.status, AiRunStatus.ready);
      expect(requests, 1);
      expect(store.ledger.report().reservedMicros, 0);
      expect(store.ledger.report().chargedMicros, 330);
      expect(store.state!.value, isNot(contains(_privateMarker)));
      expect(store.state!.value, isNot(contains(image.digest)));
      expect(store.state!.value, isNot(contains(image.dataUrl)));
      expect(store.state!.value, isNot(contains(_key)));
    },
  );

  test('old settings keep meal vision disabled', () {
    final json = const AiRuntimeSettings().toJson()
      ..remove('allowMealVision')
      ..remove('imageInputTokenCeiling');
    final migrated = AiRuntimeSettings.fromJson(json);
    expect(migrated.valid, true);
    expect(migrated.allowMealVision, false);
    expect(migrated.imageInputTokenCeiling, isNull);
  });

  testWidgets('meal review starts unchecked and applies selected foods only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 580);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final review = MealVisionReview([
      const MealVisionCandidate(label: 'Brown Rice', grams: _interval),
      const MealVisionCandidate(label: 'Soup'),
    ]);
    final catalog = [_food('rice', 'Brown Rice'), _food('soup', 'Soup')];
    List<NutritionPortion>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showMealVisionReview(context, review, catalog);
              },
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    final apply = find.widgetWithText(FilledButton, 'Use selected');
    final choice = find.byType(CheckboxListTile);
    expect(tester.widget<CheckboxListTile>(choice).value, false);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    expect(find.text('Portion unknown'), findsOneWidget);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(find.text('Energy 104–156 kcal'), findsOneWidget);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result!.single.food.id, 'rice');
    expect(result!.single.minimumAmount, 80);
    expect(result!.single.maximumAmount, 120);
  });
}

const _privateMarker = 'private source GPS marker';
const _key = 'fake-vision-key';
const _privateSourceId = 'private-photo-record-id';
const _interval = MealGramInterval(minimum: 80, maximum: 120);

DateTime _clock() => DateTime.utc(2026, 11, 24);

AiRuntimeSettings _paid({int? imageTokens = 4096}) => AiRuntimeSettings(
  route: AiRoute.api,
  apiBaseUrl: 'https://vision.example.test/v1',
  apiModel: 'image-fixture',
  monthlyCapMicros: 1000000,
  inputMicrosPerMillion: 1000000,
  outputMicrosPerMillion: 1000000,
  allowMealVision: true,
  imageInputTokenCeiling: imageTokens,
);

CaptureInput _source() => CaptureInput(
  id: _privateSourceId,
  revision: 9,
  text: _privateMarker,
  context: CaptureContext(anchor: _clock(), revision: 4),
);

AiCaptureRevision? _current(String id) =>
    id == _privateSourceId ? (sourceRevision: 9, contextRevision: 4) : null;

NutritionFood _food(
  String id,
  String name, {
  NutritionUnit unit = NutritionUnit.grams,
}) => NutritionFood(
  id: id,
  name: name,
  referenceAmount: 100,
  referenceUnit: unit,
  values: const NutritionValues(energyKcal: 130),
);

String _result(String requestId, List<Object?> candidates) => jsonEncode({
  'version': 1,
  'requestId': requestId,
  'candidates': candidates,
});

http.Response _answer(
  http.Request request,
  AiVisionImage expected, {
  bool usage = false,
}) {
  expect(request.followRedirects, false);
  expect(request.body, isNot(contains(_privateSourceId)));
  expect(request.body, isNot(contains(_privateMarker)));
  final payload = jsonDecode(request.body) as Map<String, dynamic>;
  final messages = payload['messages'] as List;
  final parts = (messages[1] as Map)['content'] as List;
  expect(parts.length, 2);
  expect((parts[0] as Map)['type'], 'text');
  final text = jsonDecode((parts[0] as Map)['text'] as String) as Map;
  expect(text.keys, ['requestId']);
  expect((parts[1] as Map)['type'], 'image_url');
  expect(((parts[1] as Map)['image_url'] as Map)['url'], expected.dataUrl);
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {
            'content': _result(text['requestId'] as String, [
              {
                'label': 'Brown Rice',
                'grams': {'minimum': 80, 'maximum': 120},
              },
            ]),
          },
        },
      ],
      if (usage) 'usage': {'prompt_tokens': 290, 'completion_tokens': 40},
    }),
    200,
  );
}

Future<Uint8List> _photo() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffe7935d), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(800, 400);
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
  image.dispose();
  picture.dispose();
  final marker = latin1.encode('tEXtNotes\u0000$_privateMarker');
  final chunk = ByteData(4)..setUint32(0, marker.length - 4);
  final crc = ByteData(4)..setUint32(0, _crc32(marker));
  return (BytesBuilder()
        ..add(Uint8List.sublistView(png, 0, png.length - 12))
        ..add(chunk.buffer.asUint8List())
        ..add(marker)
        ..add(crc.buffer.asUint8List())
        ..add(Uint8List.sublistView(png, png.length - 12)))
      .takeBytes();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  return crc ^ 0xffffffff;
}

List<String> _pngTypes(Uint8List png) {
  final view = ByteData.sublistView(png);
  final types = <String>[];
  for (var offset = 8; offset + 12 <= png.length;) {
    types.add(String.fromCharCodes(png, offset + 4, offset + 8));
    offset += view.getUint32(offset) + 12;
  }
  return types;
}

class _Store {
  _Store(Future<http.Response> Function(http.Request) send)
    : client = MockClient(send);

  final MockClient client;
  AiStoredState? state;

  late final runtime = AiRuntime(
    read: () async => state,
    compareAndSwap: (expected, value) async {
      if ((state?.revision ?? 0) != expected) return null;
      state = AiStoredState(revision: expected + 1, value: value);
      return expected + 1;
    },
    transport: client,
    clock: _clock,
  );

  AiBudgetLedger get ledger => AiBudgetLedger.decode(
    jsonEncode((jsonDecode(state!.value) as Map)['budget']),
    clock: _clock,
  );

  void dispose() {
    runtime.dispose();
    client.close();
  }
}
