import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy/nutrition/android_meal_photo_recovery.dart';
import 'package:easy/nutrition/nutrition_model.dart';
import 'package:easy/storage/attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAE0lEQVR4nGP8uCGkhwEKmBiQAAA76wKFcwHU0gAAAABJRU5ErkJggg==',
);

void main() {
  late Directory root;
  late Directory cache;
  late File selected;
  late AttachmentStore store;
  late Map<String, NutritionMeal> saved;
  late int pickerCalls;
  late int storeCalls;
  late int draftCalls;

  File pending() =>
      File.fromUri(root.uri.resolve('easy/android-meal-photo/photo'));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('easy-meal-recovery-test-');
    cache = await Directory.fromUri(root.uri.resolve('cache')).create();
    selected = File.fromUri(cache.uri.resolve('test.png'));
    await selected.writeAsBytes(_png);
    store = (await openAttachmentStore(
      directoryPath: '${root.path}/attachments',
    ))!;
    saved = {};
    pickerCalls = storeCalls = draftCalls = 0;
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  LostDataResponse resultFor(File source) =>
      LostDataResponse(type: RetrieveType.image, files: [XFile(source.path)]);

  AndroidMealPhotoRecovery recovery({
    Future<LostDataResponse> Function()? pick,
    Future<AttachmentStore?> Function()? openStore,
    Future<String> Function()? locateCache,
    Future<bool> Function(NutritionMeal)? commit,
  }) => AndroidMealPhotoRecovery(
    cacheDirectory: locateCache ?? (() async => cache.path),
    supportDirectory: () async => root.path,
    retrieveLostData: () async {
      pickerCalls++;
      return pick == null ? resultFor(selected) : await pick();
    },
    openAttachments: () async {
      storeCalls++;
      return openStore == null ? store : await openStore();
    },
    commitDraft: (draft) async {
      draftCalls++;
      if (commit != null) return commit(draft);
      if (saved.containsKey(draft.id)) return false;
      saved[draft.id] = draft;
      return true;
    },
  );

  test('empty picker result creates no attachment or meal', () async {
    final helper = recovery(pick: () async => LostDataResponse.empty());
    expect(await helper.recover(), isNull);
    expect(pickerCalls, 1);
    expect(storeCalls, 0);
    expect(draftCalls, 0);
    expect(await pending().exists(), isFalse);
  });

  test('two requests share one picker and one local draft', () async {
    final result = Completer<LostDataResponse>();
    final helper = recovery(pick: () => result.future);
    final first = helper.recover();
    final other = helper.recover();
    expect(identical(first, other), isTrue);
    result.complete(resultFor(selected));
    final meal = (await first)!;
    expect(meal, same(await other));
    expect(meal.draft, isTrue);
    expect(meal.name, 'Recovered meal photo');
    expect(meal.portions, isEmpty);
    expect(meal.photo!.format, AttachmentFormat.png);
    expect((await store.read(meal.photo!.id)).bytes, _png);
    expect(pickerCalls, 1);
    expect(storeCalls, 1);
    expect(draftCalls, 1);
    expect(saved.values, [meal]);
    expect(await pending().exists(), isFalse);
  });

  test(
    'a regenerated picker cache file does not create a second draft',
    () async {
      final first = (await recovery().recover())!;
      expect(await pending().exists(), isFalse);
      final replay = File.fromUri(cache.uri.resolve('scaled-again.png'));
      await replay.writeAsBytes(_png);
      await replay.setLastModified(
        (await selected.lastModified()).add(const Duration(minutes: 5)),
      );
      expect(
        await recovery(pick: () async => resultFor(replay)).recover(),
        isNull,
      );
      expect(pickerCalls, 2);
      expect(draftCalls, 2);
      expect(saved.values, [first]);
    },
  );

  test(
    'restages from a durable photo after the original cache is purged',
    () async {
      final rejected = recovery(openStore: () async => null);
      await expectLater(
        rejected.recover(),
        throwsA(isA<AttachmentStoreException>()),
      );
      expect(await pending().readAsBytes(), _png);
      expect(saved, isEmpty);
      await selected.delete();

      final restarted = recovery(
        pick: () async => throw StateError('Picker drained twice'),
      );
      final meal = (await restarted.recover())!;
      expect((await store.read(meal.photo!.id)).bytes, _png);
      expect(pickerCalls, 1);
      expect(draftCalls, 1);
      expect(saved.values, [meal]);
      expect(await pending().exists(), isFalse);
    },
  );

  test(
    'a temporary pre-staging failure does not drain the picker again',
    () async {
      var available = false;
      final helper = recovery(
        locateCache: () async {
          if (!available) {
            throw const FileSystemException('Cache is temporarily unavailable');
          }
          return cache.path;
        },
      );
      await expectLater(helper.recover(), throwsA(isA<FileSystemException>()));
      expect(storeCalls, 0);
      expect(await pending().exists(), isFalse);
      available = true;
      expect(await helper.recover(), isNotNull);
      expect(pickerCalls, 1);
      expect(draftCalls, 1);
    },
  );

  test(
    'an acknowledged draft ID remains the same if the first response is lost',
    () async {
      final helper = recovery(
        commit: (draft) async {
          saved[draft.id] = draft;
          throw StateError('Lost write acknowledgement');
        },
      );
      await expectLater(helper.recover(), throwsStateError);
      expect(await pending().exists(), isTrue);
      await selected.delete();
      final existing = saved.values.single;
      final restarted = recovery(
        commit: (draft) async {
          expect(draft.toJson(), existing.toJson());
          return false;
        },
      );
      expect(await restarted.recover(), isNull);
      expect(pickerCalls, 1);
      expect(draftCalls, 2);
      expect(saved.values, [existing]);
      expect(await pending().exists(), isFalse);
    },
  );

  test('invalid photo signatures cannot reach managed storage', () async {
    await selected.writeAsString('not a photo');
    await expectLater(recovery().recover(), throwsFormatException);
    expect(await pending().exists(), isFalse);
    expect(storeCalls, 0);
    expect(draftCalls, 0);
  });

  test('out-of-cache paths and symlinks cannot be recovered', () async {
    final outside = File.fromUri(root.uri.resolve('outside.png'));
    await outside.writeAsBytes(_png);
    final link = Link.fromUri(cache.uri.resolve('linked.png'));
    await link.create(outside.path);
    for (final source in [outside, File(link.path)]) {
      final helper = recovery(pick: () async => resultFor(source));
      await expectLater(helper.recover(), throwsFormatException);
      expect(await pending().exists(), isFalse);
    }
    expect(storeCalls, 0);
    expect(draftCalls, 0);
  });

  test(
    'invalid picker type, count, and oversized file cannot stage data',
    () async {
      for (final result in [
        LostDataResponse(
          type: RetrieveType.video,
          files: [XFile(selected.path)],
        ),
        LostDataResponse(
          type: RetrieveType.image,
          files: [XFile(selected.path), XFile(selected.path)],
        ),
      ]) {
        await expectLater(
          recovery(pick: () async => result).recover(),
          throwsFormatException,
        );
      }
      final large = await selected.open(mode: FileMode.write);
      await large.truncate(AttachmentLimits.photoByteLimit + 1);
      await large.close();
      await expectLater(recovery().recover(), throwsFormatException);
      expect(await pending().exists(), isFalse);
      expect(storeCalls, 0);
      expect(draftCalls, 0);
    },
  );
}
