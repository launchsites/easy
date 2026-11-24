import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/helpers.dart';

import 'src/sync_change.dart';
import 'src/sync_security.dart';
import 'src/sync_wire.dart';

const _prefix = 'easy-pair1:';
const _lifetime = Duration(minutes: 5);
const _clockAllowance = Duration(minutes: 1);
const _maximumCodeLength = 4096;
const _keyLength = 32;
const _signatureLength = 64;
const _sasAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

final _ephemeralAlgorithm = X25519();
final _macAlgorithm = Hmac.sha256();
final _pairingKdf = Hkdf(hmac: _macAlgorithm, outputLength: 69);

typedef SyncPairingClock = DateTime Function();

DateTime _utcNow() => DateTime.now().toUtc();

final class SyncPairingException implements Exception {
  const SyncPairingException(this.message);

  final String message;
  @override
  String toString() => message;
}

const _invalidProof = SyncPairingException(
  'The pairing code could not be authenticated.',
);
const _expired = SyncPairingException(
  'This invitation expired. Start a new one on the other device.',
);
const _closed = SyncPairingException('This pairing is already closed.');

final class SyncPairingOfferSummary {
  const SyncPairingOfferSummary._(
    this.workspaceId,
    this.sender,
    this.expiresAt,
  );

  final SyncWorkspaceId workspaceId;
  final SyncDevicePublicKey sender;
  final DateTime expiresAt;
}

/// Reviews an in-person invitation without approving a device or saving keys.
Future<SyncPairingOfferSummary> inspectSyncPairingInvitation(
  String code, {
  SyncPairingClock now = _utcNow,
}) async {
  final offer = await _Offer.read(code, now);
  try {
    return SyncPairingOfferSummary._(
      offer.workspace,
      offer.peer.identity,
      offer.expiresAt,
    );
  } finally {
    offer.secret.fillRange(0, offer.secret.length, 0);
  }
}

/// A short-lived invitation containing an out-of-band random secret. Exchange
/// the invitation in person, then compare both screens before confirming.
final class SyncPairingInvitation {
  SyncPairingInvitation._(
    this._offer,
    this._exchange,
    this._now,
    this._proof,
    this._identity,
  );

  static Future<SyncPairingInvitation> create({
    required SyncWorkspaceId workspaceId,
    required SyncDeviceIdentity identity,
    SyncPairingClock now = _utcNow,
  }) async {
    final exchange = await _ephemeralAlgorithm.newKeyPair();
    final secret = syncRandomBytes(_keyLength);
    try {
      final offer = _Offer(
        id: SyncWorkspaceId.generate(),
        workspace: workspaceId,
        issuedAt: now().toUtc(),
        peer: _Peer(identity.publicKey, await exchange.extractPublicKey()),
        secret: secret,
      );
      final proof = await identity.signPairingProof(offer.transcript);
      return SyncPairingInvitation._(offer, exchange, now, proof, identity);
    } catch (_) {
      exchange.destroy();
      secret.fillRange(0, secret.length, 0);
      rethrow;
    }
  }

  final _Offer _offer;
  final SimpleKeyPair _exchange;
  final SyncPairingClock _now;
  final Uint8List _proof;
  final SyncDeviceIdentity _identity;
  var _used = false;

  DateTime get expiresAt => _offer.expiresAt;

  String get code {
    _ensureOpen();
    return _encode({
      ..._offer.wire(),
      'secret': base64Url.encode(_offer.secret),
      'proof': base64Url.encode(_proof),
    });
  }

  Future<SyncPairingReview> receiveResponse(String response) async {
    _ensureOpen();
    final parsed = _Response.read(response);
    if (parsed.offer != _offer.id ||
        parsed.workspace != _offer.workspace ||
        parsed.peer.identity.fingerprint == _offer.peer.identity.fingerprint) {
      throw _invalidProof;
    }
    // Reserve this invitation before awaiting crypto. Starting again creates a
    // fresh secret, so there is at most one matching response attempt.
    _used = true;
    _PairingKeys? keys;
    try {
      final responseTranscript = parsed.transcript(_offer);
      if (!await parsed.peer.identity.verifyPairingProof(
        responseTranscript,
        parsed.proof,
      )) {
        throw _invalidProof;
      }
      keys = await _derive(
        _offer,
        responseTranscript,
        _exchange,
        parsed.peer.ephemeral,
      );
      if (!await keys.matches('response', parsed.mac)) throw _invalidProof;
      if (!_now().isBefore(expiresAt)) throw _expired;
      final review = SyncPairingReview._(
        offer: _offer,
        peer: parsed.peer.identity,
        identity: _identity,
        role: _Role.inviter,
        clock: _now,
        keys: keys,
      );
      keys = null;
      return review;
    } finally {
      keys?.destroy();
      _destroy();
    }
  }

  void cancel() {
    if (_used) return;
    _used = true;
    _destroy();
  }

  void _ensureOpen() {
    if (_used) throw _closed;
    if (!_now().isBefore(expiresAt)) {
      cancel();
      throw _expired;
    }
  }

  void _destroy() {
    _exchange.destroy();
    _offer.secret.fillRange(0, _offer.secret.length, 0);
  }
}

final class SyncPairingResponse {
  const SyncPairingResponse._(this.code, this.review);

  final String code;
  final SyncPairingReview review;
}

/// Generates the other device's response. Both devices still have to compare
/// their confirmation codes and exchange approval receipts.
Future<SyncPairingResponse> respondToSyncPairingInvitation({
  required String invitation,
  required SyncDeviceIdentity identity,
  SyncPairingClock now = _utcNow,
}) async {
  final offer = await _Offer.read(invitation, now);
  SimpleKeyPair? exchange;
  _PairingKeys? keys;
  try {
    if (offer.peer.identity.fingerprint == identity.deviceId) {
      throw const SyncPairingException(
        'Choose a different device for pairing.',
      );
    }
    exchange = await _ephemeralAlgorithm.newKeyPair();
    final peer = _Peer(identity.publicKey, await exchange.extractPublicKey());
    final fields = _Response.fields(offer.id, offer.workspace, peer);
    final transcript = _responseTranscript(offer, fields);
    keys = await _derive(offer, transcript, exchange, offer.peer.ephemeral);
    final proof = await identity.signPairingProof(transcript);
    final code = _encode({
      ...fields,
      'proof': base64Url.encode(proof),
      'mac': base64Url.encode((await keys.mac('response')).bytes),
    });
    if (!now().isBefore(offer.expiresAt)) throw _expired;
    final review = SyncPairingReview._(
      offer: offer,
      peer: offer.peer.identity,
      identity: identity,
      role: _Role.responder,
      clock: now,
      keys: keys,
    );
    keys = null;
    return SyncPairingResponse._(code, review);
  } finally {
    exchange?.destroy();
    keys?.destroy();
    offer.secret.fillRange(0, offer.secret.length, 0);
  }
}

enum _Role { inviter, responder }

/// An authenticated exchange awaiting deliberate local and remote approval.
final class SyncPairingReview {
  SyncPairingReview._({
    required _Offer offer,
    required this.peer,
    required this._identity,
    required this._role,
    required this._clock,
    required this._keys,
  }) : workspaceId = offer.workspace,
       expiresAt = offer.expiresAt,
       _offerId = offer.id;

  final SyncWorkspaceId workspaceId;
  final DateTime expiresAt;
  String get localDeviceId => _identity.deviceId;
  final SyncDevicePublicKey peer;
  final SyncDeviceIdentity _identity;
  final SyncWorkspaceId _offerId;
  final _Role _role;
  final SyncPairingClock _clock;
  final _PairingKeys _keys;
  var _locallyApproved = false;
  var _done = false;

  String get comparisonCode {
    _ensureOpen();
    return _keys.sas;
  }

  /// The code read or shown by the other device confirms the human comparison.
  /// The returned receipt contains cryptographic proof of local approval.
  Future<String> confirmComparison(String otherDeviceCode) async {
    _ensureOpen();
    final canonical = otherDeviceCode.length <= 12
        ? otherDeviceCode.trim().toUpperCase().replaceAll('-', '')
        : '';
    if (!constantTimeBytesEquality.equals(
      canonical.codeUnits,
      _keys.sas.replaceAll('-', '').codeUnits,
    )) {
      cancel();
      throw const SyncPairingException(
        'The two devices showed different pairing codes.',
      );
    }
    final mac = await _keys.mac('approve ${_role.name}');
    final fields = _approvalFields(_role, base64Url.encode(mac.bytes));
    final proof = await _identity.signPairingProof(_approvalTranscript(fields));
    _ensureOpen();
    _locallyApproved = true;
    return _encode({...fields, 'proof': base64Url.encode(proof)});
  }

  Future<PairedSyncDevice> finish(String otherDeviceApproval) async {
    _ensureOpen();
    if (!_locallyApproved) {
      throw const SyncPairingException(
        'Compare and approve the two pairing codes first.',
      );
    }
    final approval = _decode(otherDeviceApproval, 'approval', 6);
    final other = _role == _Role.inviter ? _Role.responder : _Role.inviter;
    if (approval['workspace'] != workspaceId.value ||
        approval['offer'] != _offerId.value ||
        approval['role'] != other.name ||
        !await _keys.matches(
          'approve ${other.name}',
          _bytes(approval['mac'], _keyLength),
        ) ||
        !await peer.verifyPairingProof(
          _approvalTranscript(
            _approvalFields(other, approval['mac'] as String),
          ),
          _bytes(approval['proof'], _signatureLength),
        )) {
      throw _invalidProof;
    }
    _ensureOpen();
    final paired = PairedSyncDevice._(
      workspaceId,
      localDeviceId,
      peer,
      SyncPairKey.fromBytes(_keys.bundleKey),
    );
    cancel();
    return paired;
  }

  Map<String, Object> _approvalFields(_Role role, String mac) => {
    'kind': 'approval',
    'workspace': workspaceId.value,
    'offer': _offerId.value,
    'role': role.name,
    'mac': mac,
  };

  String _approvalTranscript(Map<String, Object> fields) =>
      '${syncHex(_keys.transcriptDigest)}\n${jsonEncode(fields)}';

  void cancel() {
    if (_done) return;
    _done = true;
    _keys.destroy();
  }

  void _ensureOpen() {
    if (_done) throw _closed;
    if (!_clock().isBefore(expiresAt)) {
      cancel();
      throw _expired;
    }
  }
}

/// An approved device and a secret that can be moved once into the vault.
final class PairedSyncDevice {
  PairedSyncDevice._(
    this.workspaceId,
    this.localDeviceId,
    this.publicKey,
    this._key,
  );

  final SyncWorkspaceId workspaceId;
  final String localDeviceId;
  final SyncDevicePublicKey publicKey;
  SyncPairKey? _key;
  var _saving = false;

  SyncPairKey takeKey() {
    final key = _key;
    if (key == null || _saving) throw _closed;
    _key = null;
    return key;
  }

  void discard() {
    if (_saving) return;
    _key?.destroy();
    _key = null;
  }

  /// Saves the confirmed key through a trusted host transaction. The pairing
  /// remains available for retry if the host could not complete that write.
  Future<T> persistWith<T>(Future<T> Function(SyncPairKey) save) async {
    final key = _key;
    if (key == null || _saving) throw _closed;
    _saving = true;
    try {
      final result = await save(key);
      _key = null;
      key.destroy();
      return result;
    } finally {
      _saving = false;
    }
  }
}

final class _Peer {
  const _Peer(this.identity, this.ephemeral);

  factory _Peer.read(Map<String, dynamic> fields) => _Peer(
    SyncDevicePublicKey.fromBytes(_bytes(fields['identity'], _keyLength)),
    SimplePublicKey(
      _bytes(fields['ephemeral'], _keyLength),
      type: KeyPairType.x25519,
    ),
  );

  final SyncDevicePublicKey identity;
  final SimplePublicKey ephemeral;

  Map<String, Object> wire() => {
    'identity': base64Url.encode(identity.key.bytes),
    'ephemeral': base64Url.encode(ephemeral.bytes),
  };
}

final class _Offer {
  const _Offer({
    required this.id,
    required this.workspace,
    required this.issuedAt,
    required this.peer,
    required this.secret,
  });

  static Future<_Offer> read(String raw, SyncPairingClock now) async {
    final fields = _decode(raw, 'offer', 9);
    final issued = fields['issued'];
    if (issued is! int ||
        issued <= 0 ||
        issued > now().add(_clockAllowance).millisecondsSinceEpoch) {
      throw const FormatException('Invalid pairing invitation date.');
    }
    final issuedAt = DateTime.fromMillisecondsSinceEpoch(issued, isUtc: true);
    if (!now().isBefore(issuedAt.add(_lifetime))) throw _expired;
    final secret = _bytes(fields['secret'], _keyLength);
    try {
      final offer = _Offer(
        id: _id(fields['offer']),
        workspace: _id(fields['workspace']),
        issuedAt: issuedAt,
        peer: _Peer.read(fields),
        secret: secret,
      );
      if (fields['secretDigest'] != offer._secretDigest ||
          !await offer.peer.identity.verifyPairingProof(
            offer.transcript,
            _bytes(fields['proof'], _signatureLength),
          )) {
        throw _invalidProof;
      }
      return offer;
    } catch (_) {
      secret.fillRange(0, secret.length, 0);
      rethrow;
    }
  }

  final SyncWorkspaceId id;
  final SyncWorkspaceId workspace;
  final DateTime issuedAt;
  final _Peer peer;
  final Uint8List secret;
  DateTime get expiresAt => issuedAt.add(_lifetime);
  String get _secretDigest => crypto.sha256.convert(secret).toString();
  String get transcript => jsonEncode(wire());

  Map<String, Object> wire() => {
    'kind': 'offer',
    'workspace': workspace.value,
    'offer': id.value,
    'issued': issuedAt.millisecondsSinceEpoch,
    ...peer.wire(),
    'secretDigest': _secretDigest,
  };
}

final class _Response {
  const _Response(this.offer, this.workspace, this.peer, this.proof, this.mac);

  factory _Response.read(String raw) {
    final input = _decode(raw, 'response', 7);
    return _Response(
      _id(input['offer']),
      _id(input['workspace']),
      _Peer.read(input),
      _bytes(input['proof'], _signatureLength),
      _bytes(input['mac'], _keyLength),
    );
  }

  final SyncWorkspaceId offer;
  final SyncWorkspaceId workspace;
  final _Peer peer;
  final Uint8List proof;
  final Uint8List mac;

  String transcript(_Offer original) =>
      _responseTranscript(original, fields(offer, workspace, peer));

  static Map<String, Object> fields(
    SyncWorkspaceId offer,
    SyncWorkspaceId workspace,
    _Peer peer,
  ) => {
    'kind': 'response',
    'offer': offer.value,
    'workspace': workspace.value,
    ...peer.wire(),
  };
}

String _responseTranscript(_Offer offer, Map<String, Object> publicFields) =>
    '${offer.transcript}\n${jsonEncode(publicFields)}';

Future<_PairingKeys> _derive(
  _Offer offer,
  String transcript,
  SimpleKeyPair local,
  SimplePublicKey remote,
) async {
  final SecretKey shared;
  try {
    shared = await _ephemeralAlgorithm.sharedSecretKey(
      keyPair: local,
      remotePublicKey: remote,
    );
  } on ArgumentError {
    throw _invalidProof;
  } on StateError {
    throw _invalidProof;
  }
  final common = await shared.extractBytes();
  try {
    if (common.length != _keyLength || common.every((byte) => byte == 0)) {
      throw _invalidProof;
    }
    final digest = crypto.sha256.convert(utf8.encode(transcript)).bytes;
    final material = await _pairingKdf.deriveKey(
      secretKey: shared,
      nonce: offer.secret,
      info: [...utf8.encode('Easy Manual Pairing v1\u0000'), ...digest],
    );
    try {
      return _PairingKeys(material.bytes, digest);
    } finally {
      material.destroy();
    }
  } finally {
    if (shared is SecretKeyData) shared.destroy();
  }
}

final class _PairingKeys {
  _PairingKeys(List<int> material, this.transcriptDigest)
    : bundleKey = Uint8List.fromList(material.sublist(0, 32)),
      _confirmation = SecretKeyData(
        Uint8List.fromList(material.sublist(32, 64)),
        overwriteWhenDestroyed: true,
      ),
      sas = _comparison(material.skip(64));

  final Uint8List bundleKey;
  final SecretKeyData _confirmation;
  final String sas;
  final List<int> transcriptDigest;

  Future<Mac> mac(String label) => _macAlgorithm.calculateMac([
    ...utf8.encode('$label\u0000'),
    ...transcriptDigest,
  ], secretKey: _confirmation);

  Future<bool> matches(String label, Uint8List proof) async =>
      (await mac(label)) == Mac(proof);

  void destroy() {
    bundleKey.fillRange(0, bundleKey.length, 0);
    _confirmation.destroy();
  }
}

String _comparison(Iterable<int> bytes) {
  final code = StringBuffer();
  var remaining = 0;
  var buffer = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    remaining += 8;
    while (remaining >= 5) {
      remaining -= 5;
      if (code.length == 4) code.write('-');
      code.write(_sasAlphabet[(buffer >> remaining) & 31]);
    }
    buffer &= (1 << remaining) - 1;
  }
  return code.toString();
}

String _encode(Map<String, Object?> fields) =>
    '$_prefix${base64Url.encode(utf8.encode(jsonEncode(fields)))}';

Map<String, dynamic> _decode(String code, String kind, int fieldCount) {
  if (code.length > _maximumCodeLength || !code.startsWith(_prefix)) {
    throw const FormatException('Invalid pairing code.');
  }
  try {
    final decoded = syncDecodeJson(
      utf8.decode(base64Url.decode(code.substring(_prefix.length))),
      maxChars: _maximumCodeLength,
      maxDepth: 4,
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['kind'] != kind ||
        decoded.length != fieldCount ||
        _encode(decoded) != code) {
      throw const FormatException('Invalid pairing code.');
    }
    return decoded;
  } on FormatException {
    throw const FormatException('Invalid pairing code.');
  }
}

Uint8List _bytes(Object? value, int size) {
  if (value is! String || value.length != ((size + 2) ~/ 3) * 4) {
    throw const FormatException('Invalid pairing key or proof.');
  }
  try {
    final bytes = base64Url.decode(value);
    if (bytes.length != size || base64Url.encode(bytes) != value) {
      throw const FormatException('Invalid pairing key or proof.');
    }
    return bytes;
  } on FormatException {
    throw const FormatException('Invalid pairing key or proof.');
  }
}

SyncWorkspaceId _id(Object? value) {
  if (value is! String) throw const FormatException('Invalid pairing ID.');
  return SyncWorkspaceId(value);
}
