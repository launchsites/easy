import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../storage/src/attachment_contracts.dart' show AttachmentLimits;
import 'vision_image_stub.dart'
    if (dart.library.ui) 'vision_image_flutter.dart'
    as platform;

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
  try {
    final pixels = await platform.encodeVisionPixels(original, _pixelChunks);
    return AiVisionImage._(pixels.bytes, pixels.width, pixels.height);
  } on AiVisionImageException {
    rethrow;
  } catch (_) {
    throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
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
