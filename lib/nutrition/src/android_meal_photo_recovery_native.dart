import 'dart:io';
import 'dart:isolate';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../storage/attachment_store.dart';
import '../../storage/src/attachment_media.dart';
import '../nutrition_model.dart';

/// Recovers the result of Easy's explicit Android meal-photo picker.
final class AndroidMealPhotoRecovery {
  AndroidMealPhotoRecovery({
    required this._openAttachments,
    required this._commitDraft,
    Future<LostDataResponse> Function()? retrieveLostData,
    Future<String> Function()? supportDirectory,
    Future<String> Function()? cacheDirectory,
  }) : _retrieveLostData = retrieveLostData ?? ImagePicker().retrieveLostData,
       _supportDirectory =
           supportDirectory ??
           (() async => (await getApplicationSupportDirectory()).path),
       _cacheDirectory =
           cacheDirectory ?? (() async => (await getTemporaryDirectory()).path);

  final Future<AttachmentStore?> Function() _openAttachments;
  final Future<bool> Function(NutritionMeal) _commitDraft;
  final Future<LostDataResponse> Function() _retrieveLostData;
  final Future<String> Function() _supportDirectory;
  final Future<String> Function() _cacheDirectory;
  Future<NutritionMeal?>? _running;
  XFile? _unstaged;

  /// The callback returns false when the same draft was already committed.
  Future<NutritionMeal?> recover() => _running ??= _recover().whenComplete(() {
    _running = null;
  });

  Future<NutritionMeal?> _recover() async {
    final support = Directory(await _supportDirectory());
    final recovery = Directory.fromUri(
      support.uri.resolve('easy/android-meal-photo'),
    );
    await recovery.create(recursive: true);
    final lock = await File.fromUri(recovery.uri.resolve('recovery.lock'))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      try {
        return await _recoverLocked(recovery);
      } finally {
        await lock.unlock();
      }
    } finally {
      await lock.close();
    }
  }

  Future<NutritionMeal?> _recoverLocked(Directory folder) async {
    final pending = File.fromUri(folder.uri.resolve('photo'));
    final partial = File.fromUri(folder.uri.resolve('incoming'));
    if (await partial.exists()) await partial.delete();
    if (!await pending.exists()) {
      final selected = _unstaged ?? await _readPicker();
      if (selected == null) return null;
      _unstaged = selected;
      try {
        await _stage(selected, partial, pending);
      } on FormatException {
        _unstaged = null;
        rethrow;
      }
      _unstaged = null;
    }

    final length = await _photoLength(pending);
    final pickedAt = (await pending.lastModified()).toUtc();
    final store = await _openAttachments();
    if (store == null) {
      throw const AttachmentStoreException(
        'The meal photo could not be saved.',
      );
    }
    final photo = await store.putStream(
      pending.openRead(),
      kind: AttachmentKind.photo,
      expectedLength: length,
    );
    final meal = NutritionMeal(
      // Android may regenerate the scaled cache file when a saved result replays.
      id: 'android-meal-${photo.id}',
      name: 'Recovered meal photo',
      eatenAt: pickedAt,
      photo: photo,
      draft: true,
    );
    final created = await _commitDraft(meal);
    await pending.delete();
    return created ? meal : null;
  }

  Future<XFile?> _readPicker() async {
    final result = await _retrieveLostData();
    if (result.isEmpty) return null;
    final files = result.files ?? [?result.file];
    if (result.exception != null ||
        result.type != RetrieveType.image ||
        files.length != 1 ||
        files.single.mimeType?.toLowerCase().startsWith('image/') == false) {
      throw const FormatException(
        'The previous meal photo could not be recovered.',
      );
    }
    return files.single;
  }

  Future<void> _stage(XFile selected, File partial, File pending) async {
    final path = selected.path;
    if (!path.startsWith('/')) {
      throw const FormatException('The previous photo is unavailable.');
    }
    final source = File(path);
    if (!await source.exists()) {
      throw const FormatException('The previous photo is unavailable.');
    }
    final cache = await Directory(await _cacheDirectory())
        .resolveSymbolicLinks();
    final resolved = await source.resolveSymbolicLinks();
    if (!resolved.startsWith('$cache${Platform.pathSeparator}')) {
      throw const FormatException(
        'The previous photo is outside the app cache.',
      );
    }
    final cached = File(resolved);
    final length = await _photoLength(cached);
    final pickedAt = await cached.lastModified();
    try {
      final staged = await partial.open(mode: FileMode.writeOnly);
      try {
        var written = 0;
        await for (final chunk in cached.openRead()) {
          if (chunk.length > length - written) {
            throw const FormatException('The previous photo changed size.');
          }
          await staged.writeFrom(chunk);
          written += chunk.length;
        }
        if (written != length) {
          throw const FormatException('The previous photo changed size.');
        }
        await staged.flush();
      } finally {
        await staged.close();
      }
      await _validatePhoto(partial.path, length);
      await partial.setLastModified(pickedAt);
      await partial.rename(pending.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}

Future<void> _validatePhoto(String path, int length) => Isolate.run(() {
  final format = inspectAttachment(File(path), length);
  checkAttachmentType(format, AttachmentKind.photo, null);
}, debugName: 'easy-recovered-meal-photo');

Future<int> _photoLength(File file) async {
  final length = await file.length();
  if (length <= 0 || length > AttachmentLimits.photoByteLimit) {
    throw const FormatException('The previous photo has an unsupported size.');
  }
  return length;
}
