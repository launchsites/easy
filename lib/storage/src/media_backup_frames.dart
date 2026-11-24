import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backup_password.dart';
import 'media_backup_contracts.dart';
import 'snapshot_codec.dart' show workspaceBackupByteLimit;

const mediaFrameBytes = 64 * 1024;
const mediaManifestByteLimit = 4 * 1024 * 1024;
const _formatVersion = 1;
const _saltOffset = 9;
const _nonceOffset = _saltOffset + 16;
const mediaFrameHeaderLength = _nonceOffset + 4;
const _tagBytes = 16;
const _framePrefixLength = 5;
const _finalFlag = 1;
const _maximumPayload =
    WorkspaceMediaBackupLimits.maximumMediaBytes +
    workspaceBackupByteLimit +
    mediaManifestByteLimit +
    4;
const _maximumFrames =
    (_maximumPayload + mediaFrameBytes - 1) ~/ mediaFrameBytes + 1;

int mediaArchiveLengthLimit(WorkspaceMediaBackupLimits limits) {
  final payload =
      limits.mediaBytes + workspaceBackupByteLimit + mediaManifestByteLimit + 4;
  final frames = (payload + mediaFrameBytes - 1) ~/ mediaFrameBytes + 1;
  return payload +
      mediaFrameHeaderLength +
      frames * (_framePrefixLength + _tagBytes);
}

Uint8List newMediaArchiveHeader() {
  final result = Uint8List(mediaFrameHeaderLength)
    ..setRange(0, mediaArchiveMagic.length, mediaArchiveMagic)
    ..[mediaArchiveMagic.length] = _formatVersion;
  final random = Random.secure();
  for (var index = _saltOffset; index < result.length; index++) {
    result[index] = random.nextInt(256);
  }
  return result;
}

void _verifyHeader(Uint8List bytes) {
  if (bytes.length != mediaFrameHeaderLength ||
      bytes[mediaArchiveMagic.length] != _formatVersion) {
    throw const FormatException('Unsupported media backup format.');
  }
  for (var index = 0; index < mediaArchiveMagic.length; index++) {
    if (bytes[index] != mediaArchiveMagic[index]) {
      throw const FormatException('Unsupported media backup format.');
    }
  }
}

Uint8List _prefix(int length, bool finalFrame) {
  final prefix = Uint8List(_framePrefixLength)
    ..[4] = finalFrame ? _finalFlag : 0;
  ByteData.sublistView(prefix).setUint32(0, length);
  return prefix;
}

final class MediaFrameWriter {
  MediaFrameWriter._(this._file, this._cipher);

  static Future<MediaFrameWriter> open(File output, String passphrase) async {
    final header = newMediaArchiveHeader();
    final handle = await output.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(header);
      return MediaFrameWriter._(
        handle,
        await _FrameCipher.open(header, passphrase, decrypt: false),
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  final RandomAccessFile _file;
  final _FrameCipher _cipher;
  final _buffer = Uint8List(mediaFrameBytes);
  var _count = 0;
  var _finished = false;

  Future<void> add(List<int> input) async {
    if (_finished) throw StateError('The media archive is complete.');
    for (var index = 0; index < input.length;) {
      final length = min(mediaFrameBytes - _count, input.length - index);
      _buffer.setRange(_count, _count + length, input, index);
      _count += length;
      index += length;
      if (_count == mediaFrameBytes) await _flush();
    }
  }

  Future<void> _flush() async {
    final payload = Uint8List.sublistView(_buffer, 0, _count);
    final encrypted = await _cipher.process(payload, finalFrame: false);
    await _file.writeFrom(_prefix(_count, false));
    await _file.writeFrom(encrypted);
    _count = 0;
  }

  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    if (_count > 0) await _flush();
    final finalTag = await _cipher.process(Uint8List(0), finalFrame: true);
    await _file.writeFrom(_prefix(0, true));
    await _file.writeFrom(finalTag);
    await _file.flush();
  }

  Future<void> close() async {
    try {
      await _file.close();
    } finally {
      await _cipher.close();
    }
  }
}

final class MediaFrameReader {
  MediaFrameReader._(this._input, this._cipher);

  static Future<MediaFrameReader> open(
    Stream<List<int>> source,
    String passphrase,
  ) async {
    final input = _FrameInput(source);
    try {
      final header = await input.read(mediaFrameHeaderLength);
      _verifyHeader(header);
      return MediaFrameReader._(
        input,
        await _FrameCipher.open(header, passphrase, decrypt: true),
      );
    } catch (_) {
      await input.close();
      rethrow;
    }
  }

  final _FrameInput _input;
  final _FrameCipher _cipher;
  var _frame = Uint8List(0);
  var _position = 0;
  var _finalSeen = false;

  Stream<Uint8List> take(int length) async* {
    for (var remaining = length; remaining > 0;) {
      if (_position == _frame.length) {
        if (_finalSeen || !await _next()) {
          throw const FormatException(
            'The media backup ended before its declared size.',
          );
        }
      }
      final count = min(_frame.length - _position, remaining);
      final data = Uint8List.sublistView(_frame, _position, _position + count);
      _position += count;
      remaining -= count;
      yield data;
    }
  }

  Future<Uint8List> read(int length) async {
    final result = Uint8List(length);
    var offset = 0;
    await for (final chunk in take(length)) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  Future<bool> _next() async {
    final prefix = await _input.read(_framePrefixLength);
    final length = ByteData.sublistView(prefix).getUint32(0);
    final flag = prefix[4];
    if (length > mediaFrameBytes ||
        (flag == 0 && length == 0) ||
        flag > _finalFlag ||
        (flag == _finalFlag && length != 0)) {
      throw const FormatException('Invalid encrypted media frame.');
    }
    final block = await _input.read(length + _tagBytes);
    _frame = await _cipher.process(block, finalFrame: flag == _finalFlag);
    _position = 0;
    _finalSeen = flag == _finalFlag;
    return !_finalSeen;
  }

  Future<void> expectEnd() async {
    if (_position < _frame.length ||
        !_finalSeen && await _next() ||
        await _input.hasData()) {
      throw const FormatException('Unexpected trailing media backup data.');
    }
  }

  Future<void> close() async {
    try {
      await _input.close();
    } finally {
      await _cipher.close();
    }
  }
}

final class _FrameInput {
  _FrameInput(Stream<List<int>> source) : _source = StreamIterator(source);

  final StreamIterator<List<int>> _source;
  List<int> _chunk = const [];
  var _offset = 0;

  Future<bool> hasData() async {
    while (_offset == _chunk.length) {
      if (!await _source.moveNext()) return false;
      _chunk = _source.current;
      _offset = 0;
    }
    return true;
  }

  Future<Uint8List> read(int length) async {
    final bytes = Uint8List(length);
    var position = 0;
    while (position < bytes.length) {
      if (!await hasData()) {
        throw const FormatException('The media backup is incomplete.');
      }
      final size = min(_chunk.length - _offset, bytes.length - position);
      bytes.setRange(position, position + size, _chunk, _offset);
      position += size;
      _offset += size;
    }
    return bytes;
  }

  Future<void> close() => _source.cancel();
}

final class _FrameCipher {
  final _responses = ReceivePort();
  final _ready = Completer<SendPort>();
  final _exited = Completer<void>();
  SendPort? _requests;
  Completer<Uint8List>? _pending;
  Isolate? _worker;
  var _closed = false;

  static Future<_FrameCipher> open(
    Uint8List header,
    String passphrase, {
    required bool decrypt,
  }) async {
    final cipher = _FrameCipher();
    cipher._responses.listen(cipher._receive);
    try {
      final worker = Isolate.spawn(
        _startFrameWorker,
        (header, passphrase, decrypt, cipher._responses.sendPort),
        onError: cipher._responses.sendPort,
        onExit: cipher._responses.sendPort,
        debugName: 'easy-media-backup-cipher',
      );
      final started = await Future.wait<Object>([
        cipher._ready.future,
        worker,
      ], eagerError: true);
      cipher._requests = started.first as SendPort;
      cipher._worker = started.last as Isolate;
      return cipher;
    } catch (_) {
      await cipher.close();
      rethrow;
    }
  }

  Future<Uint8List> process(Uint8List data, {required bool finalFrame}) {
    if (_closed || _pending != null || _requests == null) {
      throw const WorkspaceMediaBackupException(
        'The media backup cipher is unavailable.',
      );
    }
    final pending = Completer<Uint8List>();
    _pending = pending;
    _requests!.send((TransferableTypedData.fromList([data]), finalFrame));
    return pending.future;
  }

  void _receive(Object? message) {
    switch (message) {
      case SendPort port:
        _ready.complete(port);
      case TransferableTypedData result:
        final pending = _pending;
        _pending = null;
        pending?.complete(result.materialize().asUint8List());
      case WorkspaceMediaBackupException() ||
          WorkspaceMediaBackupAuthenticationException():
        final pending = _pending;
        _pending = null;
        if (_ready.isCompleted) {
          pending?.completeError(message!);
        } else {
          _ready.completeError(message!);
        }
      case null || List<dynamic> _:
        final error = const WorkspaceMediaBackupException(
          'The media backup cipher stopped.',
        );
        if (!_ready.isCompleted) _ready.completeError(error);
        _pending?.completeError(error);
        _pending = null;
        if (!_exited.isCompleted) _exited.complete();
        _requests = null;
        _responses.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final port = _requests;
    if (port != null) {
      port.send(null);
      try {
        await _exited.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _worker?.kill();
      }
    }
    _responses.close();
  }
}

Future<void> _startFrameWorker(
  (Uint8List, String, bool, SendPort) configuration,
) async {
  final (header, passphrase, decrypt, replies) = configuration;
  final SecretKeyData key;
  try {
    final passwordKey = await deriveBackupKey(
      passphrase,
      Uint8List.sublistView(header, _saltOffset, _nonceOffset),
    );
    try {
      key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: passwordKey,
        info: utf8.encode('Easy Media Backup v1\u0000'),
      );
    } finally {
      passwordKey.destroy();
    }
  } catch (_) {
    replies.send(
      const WorkspaceMediaBackupException(
        'The media encryption key could not be created.',
      ),
    );
    return;
  }
  final requests = ReceivePort();
  final cipher = AesGcm.with256bits();
  var counter = 0;
  replies.send(requests.sendPort);
  try {
    await for (final message in requests) {
      if (message == null) break;
      if (counter >= _maximumFrames) {
        replies.send(
          const WorkspaceMediaBackupException(
            'The media archive contains too many frames.',
          ),
        );
        break;
      }
      final (input, finalFrame) = message as (TransferableTypedData, bool);
      final bytes = input.materialize().asUint8List();
      final nonce = Uint8List(12)..setRange(0, 4, header, _nonceOffset);
      ByteData.sublistView(nonce).setUint64(4, counter++);
      final length = bytes.length - (decrypt ? _tagBytes : 0);
      final aad = [...header, ...nonce, ..._prefix(length, finalFrame)];
      try {
        final Uint8List result;
        if (decrypt) {
          final opened = await cipher.decrypt(
            SecretBox(
              Uint8List.sublistView(bytes, 0, length),
              nonce: nonce,
              mac: Mac(Uint8List.sublistView(bytes, length)),
            ),
            secretKey: key,
            aad: aad,
          );
          result = opened is Uint8List ? opened : Uint8List.fromList(opened);
        } else {
          final sealed = await cipher.encrypt(
            bytes,
            secretKey: key,
            nonce: nonce,
            aad: aad,
          );
          final cipherLength = sealed.cipherText.length;
          final tag = sealed.mac.bytes;
          result = Uint8List(cipherLength + tag.length)
            ..setRange(0, cipherLength, sealed.cipherText)
            ..setRange(cipherLength, cipherLength + tag.length, tag);
        }
        replies.send(TransferableTypedData.fromList([result]));
      } on SecretBoxAuthenticationError {
        replies.send(const WorkspaceMediaBackupAuthenticationException());
        break;
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      if (finalFrame) break;
    }
  } finally {
    key.destroy();
    requests.close();
  }
}
