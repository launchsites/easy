import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'attachment_contracts.dart';

AttachmentFormat inspectAttachment(File file, int length) {
  final handle = file.openSync();
  try {
    return inspectAttachmentHandle(handle, length);
  } finally {
    handle.closeSync();
  }
}

AttachmentFormat inspectAttachmentHandle(RandomAccessFile handle, int length) {
  final probe = _Probe(handle, length);
  final first = probe.read(0, min(length, 12));
  if (_matches(first, const [0xff, 0xd8, 0xff])) {
    _checkJpeg(probe);
    return AttachmentFormat.jpeg;
  }
  if (_matches(first, const [137, 80, 78, 71, 13, 10, 26, 10])) {
    _checkPng(probe);
    return AttachmentFormat.png;
  }
  if (_ascii(first, 0, 'RIFF') && _ascii(first, 8, 'WAVE')) {
    _checkWave(probe, first);
    return AttachmentFormat.wav;
  }
  if (_ascii(first, 4, 'ftyp')) return _checkBmff(probe);
  throw const FormatException('Unsupported photo or audio file.');
}

void checkAttachmentType(
  AttachmentFormat format,
  AttachmentKind kind,
  String? declaredMimeType,
) {
  if (format.kind != kind) {
    throw const FormatException('This file is a different kind of attachment.');
  }
  final declared = declaredMimeType?.split(';').first.trim().toLowerCase();
  if (declared == null ||
      declared == '' ||
      declared == 'application/octet-stream' ||
      declared == format.mimeType) {
    return;
  }
  final alias = switch (format) {
    AttachmentFormat.jpeg => declared == 'image/jpg',
    AttachmentFormat.png => false,
    AttachmentFormat.heic => const {
      'image/heif',
      'image/heic-sequence',
      'image/heif-sequence',
    }.contains(declared),
    AttachmentFormat.wav => const {
      'audio/wave',
      'audio/x-wav',
      'audio/vnd.wave',
    }.contains(declared),
    AttachmentFormat.m4a => const {
      'audio/m4a',
      'audio/x-m4a',
    }.contains(declared),
  };
  if (!alias) {
    throw const FormatException('The file does not match its media type.');
  }
}

class _Probe {
  _Probe(this.handle, this.length);

  final RandomAccessFile handle;
  final int length;
  int _remainingBoxes = 4096;

  Uint8List read(int offset, int count) {
    if (offset < 0 || count < 0 || offset > length - count) {
      throw const FormatException('A media field exceeds the file size.');
    }
    handle.setPositionSync(offset);
    final result = handle.readSync(count);
    if (result.length != count) {
      throw const FormatException('The media file ended unexpectedly.');
    }
    return result;
  }

  Iterable<_Box> boxes(int start, int end) sync* {
    var position = start;
    while (position < end) {
      if (--_remainingBoxes < 0 || end - position < 8) {
        throw const FormatException('Invalid media container structure.');
      }
      final header = read(position, 8);
      final sizeField = ByteData.sublistView(header).getUint32(0);
      final hasLargeSize = sizeField == 1;
      final headerBytes = hasLargeSize ? 16 : 8;
      final size = switch (sizeField) {
        0 => end - position,
        1 => ByteData.sublistView(read(position + 8, 8)).getUint64(0),
        _ => sizeField,
      };
      if (size < headerBytes || size > end - position) {
        throw const FormatException('Invalid media container box size.');
      }
      final type = _tag(header, 4);
      final boxEnd = position + size;
      yield _Box(type, position + headerBytes, boxEnd);
      position = boxEnd;
    }
  }
}

class _Box {
  const _Box(this.type, this.payload, this.end);

  final String type;
  final int payload;
  final int end;

  int get payloadBytes => end - payload;
}

void _checkJpeg(_Probe probe) {
  if (!_matches(probe.read(probe.length - 2, 2), const [0xff, 0xd9])) {
    throw const FormatException('The JPEG is incomplete.');
  }
  final header = probe.read(0, min(probe.length, 1024 * 1024));
  var offset = 2;
  while (offset + 4 <= header.length && header[offset++] == 0xff) {
    while (offset < header.length && header[offset] == 0xff) {
      offset++;
    }
    if (offset + 2 >= header.length) break;
    final marker = header[offset++];
    if (marker == 0xda || marker == 0xd9) break;
    if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd8) continue;
    final size = header[offset] * 256 + header[offset + 1];
    if (size < 2 || size > header.length - offset) break;
    if (marker >= 0xc0 &&
        marker <= 0xcf &&
        !const {0xc4, 0xc8, 0xcc}.contains(marker)) {
      if (size < 8) break;
      final height = header[offset + 3] * 256 + header[offset + 4];
      final width = header[offset + 5] * 256 + header[offset + 6];
      _checkImageDimensions(width, height);
      return;
    }
    offset += size;
  }
  throw const FormatException('The JPEG has no supported image dimensions.');
}

void _checkPng(_Probe probe) {
  if (probe.length < 45) {
    throw const FormatException('The PNG is incomplete.');
  }
  final header = probe.read(8, 16);
  final data = ByteData.sublistView(header);
  if (data.getUint32(0) != 13 ||
      !_ascii(header, 4, 'IHDR') ||
      !_matches(probe.read(probe.length - 12, 8), const [
        0, 0, 0, 0, 73, 69, 78, 68, // IEND
      ])) {
    throw const FormatException('Invalid PNG container.');
  }
  _checkImageDimensions(data.getUint32(8), data.getUint32(12));
}

void _checkImageDimensions(int width, int height) {
  const pixelLimit = 64 * 1024 * 1024;
  if (width <= 0 || height <= 0 || width > pixelLimit ~/ height) {
    throw const FormatException(
      'The image dimensions are outside the supported range.',
    );
  }
}

void _checkWave(_Probe probe, Uint8List first) {
  final end = ByteData.sublistView(first).getUint32(4, Endian.little) + 8;
  if (end != probe.length) {
    throw const FormatException('The WAV has an invalid container size.');
  }
  var hasFormat = false;
  var hasData = false;
  var position = 12;
  var remainingChunks = 4096;
  while (position < end) {
    if (--remainingChunks < 0 || end - position < 8) {
      throw const FormatException('Invalid WAV chunk structure.');
    }
    final chunk = probe.read(position, 8);
    final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
    position += 8;
    final padding = size.isOdd ? 1 : 0;
    if (size + padding > end - position) {
      throw const FormatException('A WAV chunk exceeds the file size.');
    }
    if (_ascii(chunk, 0, 'fmt ') && size >= 16) {
      final descriptor = ByteData.sublistView(probe.read(position, 16));
      hasFormat =
          descriptor.getUint16(2, Endian.little) != 0 &&
          descriptor.getUint32(4, Endian.little) != 0;
    }
    if (_ascii(chunk, 0, 'data') && size > 0) hasData = true;
    position += size + padding;
  }
  if (!hasFormat || !hasData) {
    throw const FormatException('The WAV is missing audio data or a format.');
  }
}

AttachmentFormat _checkBmff(_Probe probe) {
  final top = probe.boxes(0, probe.length).toList();
  final type = top.first;
  if (type.type != 'ftyp' ||
      type.payloadBytes < 8 ||
      type.payloadBytes > 4096 ||
      type.payloadBytes % 4 != 0) {
    throw const FormatException('Invalid media container type.');
  }
  final typeData = probe.read(type.payload, type.payloadBytes);
  final brands = {
    _tag(typeData, 0),
    for (var offset = 8; offset < typeData.length; offset += 4)
      _tag(typeData, offset),
  };
  const heicBrands = {
    'heic',
    'heix',
    'hevc',
    'hevx',
    'heim',
    'heis',
    'hevm',
    'hevs',
  };
  if (brands.any(heicBrands.contains) &&
      !brands.any({'avif', 'avis'}.contains)) {
    _checkHeic(probe, top);
    return AttachmentFormat.heic;
  }
  const audioBrands = {
    'M4A ',
    'M4B ',
    'M4P ',
    'isom',
    'iso2',
    'mp41',
    'mp42',
    'qt  ',
  };
  if (brands.any(audioBrands.contains)) {
    _checkAudioTracks(probe, top);
    return AttachmentFormat.m4a;
  }
  throw const FormatException('Unsupported media container type.');
}

void _checkHeic(_Probe probe, List<_Box> top) {
  var hasImage = false;
  for (final meta in top.where((box) => box.type == 'meta')) {
    if (meta.payloadBytes < 4) {
      throw const FormatException('Invalid HEIC metadata.');
    }
    for (final iprp
        in probe
            .boxes(meta.payload + 4, meta.end)
            .where((box) => box.type == 'iprp')) {
      for (final ipco
          in probe
              .boxes(iprp.payload, iprp.end)
              .where((box) => box.type == 'ipco')) {
        for (final image
            in probe
                .boxes(ipco.payload, ipco.end)
                .where((box) => box.type == 'ispe')) {
          if (image.payloadBytes < 12) {
            throw const FormatException('Invalid HEIC image dimensions.');
          }
          final dimensions = ByteData.sublistView(
            probe.read(image.payload + 4, 8),
          );
          _checkImageDimensions(
            dimensions.getUint32(0),
            dimensions.getUint32(4),
          );
          hasImage = true;
        }
      }
    }
  }
  if (!hasImage) {
    throw const FormatException('The HEIC is missing image dimensions.');
  }
}

void _checkAudioTracks(_Probe probe, List<_Box> top) {
  var hasAudio = false;
  for (final movie in top.where((box) => box.type == 'moov')) {
    for (final track
        in probe
            .boxes(movie.payload, movie.end)
            .where((box) => box.type == 'trak')) {
      for (final media
          in probe
              .boxes(track.payload, track.end)
              .where((box) => box.type == 'mdia')) {
        for (final handler
            in probe
                .boxes(media.payload, media.end)
                .where((box) => box.type == 'hdlr')) {
          if (handler.payloadBytes < 12) {
            throw const FormatException('Invalid media track.');
          }
          final type = _tag(probe.read(handler.payload + 8, 4), 0);
          if (type == 'vide') {
            throw const FormatException(
              'An audio attachment cannot contain video.',
            );
          }
          if (type == 'soun') hasAudio = true;
        }
      }
    }
  }
  if (!hasAudio) {
    throw const FormatException('The file contains no audio track.');
  }
}

bool _matches(Uint8List bytes, List<int> sequence) {
  if (bytes.length < sequence.length) return false;
  for (var index = 0; index < sequence.length; index++) {
    if (bytes[index] != sequence[index]) return false;
  }
  return true;
}

bool _ascii(Uint8List bytes, int offset, String text) {
  if (bytes.length - offset < text.length) return false;
  for (var index = 0; index < text.length; index++) {
    if (bytes[offset + index] != text.codeUnitAt(index)) return false;
  }
  return true;
}

String _tag(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes, offset, offset + 4);
