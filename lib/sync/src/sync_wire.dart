import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const maxSyncDevices = 64;
const maxSyncChangeBytes = 128 * 1024;
const maxSyncCounter = 0x1fffffffffffff;

final syncDeviceIdPattern = RegExp(r'^[a-f0-9]{64}$');
final _secureRandom = Random.secure();

bool syncMatches(RegExp pattern, String value) =>
    pattern.matchAsPrefix(value)?.end == value.length;

Uint8List syncRandomBytes(int length) => Uint8List.fromList([
  for (var index = 0; index < length; index++) _secureRandom.nextInt(256),
]);

String syncHex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List syncHexBytes(String validatedHex) => Uint8List.fromList([
  for (var index = 0; index < validatedHex.length; index += 2)
    int.parse(validatedHex.substring(index, index + 2), radix: 16),
]);

Uint8List syncFixedBytes(List<int> bytes, int size, String label) {
  if (bytes.length != size || bytes.any((byte) => byte < 0 || byte > 255)) {
    throw FormatException('Invalid $label length or byte value.');
  }
  return Uint8List.fromList(bytes);
}

Object? syncDecodeJson(
  String text, {
  required int maxChars,
  int maxDepth = 24,
}) {
  if (text.length > maxChars) {
    throw const FormatException('Sync data exceeds its size limit.');
  }
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final code in text.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5c) {
        escaped = true;
      } else if (code == 0x22) {
        quoted = false;
      }
    } else if (code == 0x22) {
      quoted = true;
    } else if (code == 0x5b || code == 0x7b) {
      if (++depth > maxDepth) {
        throw const FormatException('Sync data is nested too deeply.');
      }
    } else if (code == 0x5d || code == 0x7d) {
      if (--depth < 0) throw const FormatException('Invalid sync data.');
    }
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    throw const FormatException('Invalid sync data.');
  }
}
