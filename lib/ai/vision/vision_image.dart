import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import '../../storage/attachment_store.dart' show AttachmentLimits;

/// A pixel-only derivative prepared for one meal-photo request.
final class AiVisionImage {
  AiVisionImage._(Uint8List data, this.width, this.height)
    : bytes = data.asUnmodifiableView(),
      digest = sha256.convert(data).toString();

  static const mimeType = 'image/png';
  static const maxEdge = 640;
  static const maxBytes = 384 * 1024;

  final Uint8List bytes;
  final int width;
  final int height;
  final String digest;

  String get dataUrl => 'data:$mimeType;base64,${base64.encode(bytes)}';
}

enum AiVisionImageFailure { invalidImage, sourceTooLarge, derivativeTooLarge }

class AiVisionImageException implements Exception {
  const AiVisionImageException(this.reason);

  final AiVisionImageFailure reason;
}

/// Decodes a bounded photo and serializes its first frame from pixels.
/// The transport only accepts the resulting [AiVisionImage].
Future<AiVisionImage> prepareAiVisionImage(Uint8List original) async {
  if (original.isEmpty) {
    throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
  }
  if (original.length > AttachmentLimits.photoByteLimit) {
    throw const AiVisionImageException(AiVisionImageFailure.sourceTooLarge);
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(original);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width < 1 || height < 1) {
      throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
    }
    if (height > 50000000 ~/ width) {
      throw const AiVisionImageException(AiVisionImageFailure.sourceTooLarge);
    }
    var longest = math.min(math.max(width, height), AiVisionImage.maxEdge);
    final originalEdge = math.max(width, height);
    while (true) {
      final nextWidth = math.max(1, width * longest ~/ originalEdge);
      final nextHeight = math.max(1, height * longest ~/ originalEdge);
      final codec = await descriptor.instantiateCodec(
        targetWidth: nextWidth,
        targetHeight: nextHeight,
      );
      ui.Image? pixels;
      try {
        pixels = (await codec.getNextFrame()).image;
        final encoded = await pixels.toByteData(format: ui.ImageByteFormat.png);
        if (encoded == null) {
          throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
        }
        final data = _pixelChunks(
          encoded.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          ),
        );
        if (data.length <= AiVisionImage.maxBytes) {
          return AiVisionImage._(data, pixels.width, pixels.height);
        }
      } finally {
        pixels?.dispose();
        codec.dispose();
      }
      if (longest <= 128) {
        throw const AiVisionImageException(
          AiVisionImageFailure.derivativeTooLarge,
        );
      }
      longest = math.max(128, longest * 3 ~/ 4);
    }
  } on AiVisionImageException {
    rethrow;
  } catch (_) {
    throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

const _signature = [137, 80, 78, 71, 13, 10, 26, 10];
const _pixelData = {'IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'};

Uint8List _pixelChunks(Uint8List png) {
  if (png.length < _signature.length ||
      !_signature.asMap().entries.every(
        (item) => png[item.key] == item.value,
      )) {
    throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
  }
  final view = ByteData.sublistView(png);
  final output = BytesBuilder(copy: false)..add(_signature);
  var offset = _signature.length;
  while (offset <= png.length - 12) {
    final length = view.getUint32(offset);
    if (length > png.length - offset - 12) break;
    final type = String.fromCharCodes(png, offset + 4, offset + 8);
    final end = offset + 12 + length;
    if (_pixelData.contains(type)) {
      output.add(Uint8List.sublistView(png, offset, end));
    }
    if (type == 'IEND' && length == 0 && end == png.length) {
      return output.takeBytes();
    }
    offset = end;
  }
  throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
}
