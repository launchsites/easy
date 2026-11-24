import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'sync_change.dart';
import 'sync_wire.dart';

const _signatureBytes = 64;
const _signatureTextLength = 88;
const _publicKeyBytes = 32;
const _pairKeyBytes = 32;
const _signatureDomain = 'Easy Sync Change v1\u0000';
const _pairingProofDomain = 'Easy Pairing Proof v1\u0000';

final _signatureAlgorithm = Ed25519();
final _encryptionAlgorithm = AesGcm.with256bits();

/// A public key pinned through an explicitly approved pairing flow.
final class SyncDevicePublicKey {
  factory SyncDevicePublicKey.fromBytes(List<int> bytes) {
    final copy = syncFixedBytes(bytes, _publicKeyBytes, 'device key');
    return SyncDevicePublicKey._(crypto.sha256.convert(copy).toString(), copy);
  }

  const SyncDevicePublicKey._(this.fingerprint, this._bytes);

  final String fingerprint;
  final Uint8List _bytes;

  SimplePublicKey get key =>
      SimplePublicKey(Uint8List.fromList(_bytes), type: KeyPairType.ed25519);

  Future<bool> verifyPairingProof(String transcript, Uint8List proof) =>
      _signatureAlgorithm.verify(
        _pairingProofBytes(transcript),
        signature: Signature(Uint8List.fromList(proof), publicKey: key),
      );
}

final class SyncDeviceIdentity {
  const SyncDeviceIdentity._(this._keyPair, this.publicKey);

  static Future<SyncDeviceIdentity> generate() async {
    final pair = await _signatureAlgorithm.newKeyPair();
    return _import(pair);
  }

  /// Use a secure, randomly generated 32-byte seed from the host key store.
  static Future<SyncDeviceIdentity> fromSeed(List<int> seed) async {
    final copy = syncFixedBytes(seed, _publicKeyBytes, 'device seed');
    try {
      return await _import(await _signatureAlgorithm.newKeyPairFromSeed(copy));
    } finally {
      copy.fillRange(0, copy.length, 0);
    }
  }

  static Future<SyncDeviceIdentity> _import(SimpleKeyPair pair) async {
    final public = await pair.extractPublicKey();
    return SyncDeviceIdentity._(
      pair,
      SyncDevicePublicKey.fromBytes(public.bytes),
    );
  }

  final SimpleKeyPair _keyPair;
  final SyncDevicePublicKey publicKey;

  String get deviceId => publicKey.fingerprint;

  Future<Uint8List> signPairingProof(String transcript) async =>
      Uint8List.fromList(
        (await _signatureAlgorithm.sign(
          _pairingProofBytes(transcript),
          keyPair: _keyPair,
        )).bytes,
      );

  Future<Uint8List> copySeedForSecureStorage() async =>
      Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());

  void destroy() => _keyPair.destroy();

  Future<SignedSyncChange> sign(SyncChange change) async {
    if (change.dot.deviceId != deviceId) {
      throw const SyncTrustException('A device can sign its own changes.');
    }
    final signature = await _signatureAlgorithm.sign(
      _signingBytes(change),
      keyPair: _keyPair,
    );
    return SignedSyncChange._(change, Uint8List.fromList(signature.bytes));
  }
}

final class SignedSyncChange {
  SignedSyncChange._(this.change, Uint8List signature)
    : signature = signature.asUnmodifiableView();

  /// Decodes an untrusted signed change. Call [SyncTrust.verify] before use.
  factory SignedSyncChange.decode(String raw) => SignedSyncChange._fromWire(
    syncDecodeJson(raw, maxChars: _maximumBatchBytes),
  );

  factory SignedSyncChange._fromWire(Object? input) {
    if (input is! List ||
        input.length != 2 ||
        input[0] is! String ||
        input[1] is! String) {
      throw const FormatException('Invalid signed sync change.');
    }
    final payload = input[0] as String;
    final signatureText = input[1] as String;
    if (signatureText.length != _signatureTextLength) {
      throw const FormatException('Invalid sync signature length.');
    }
    final signature = base64Url.decode(signatureText);
    if (signature.length != _signatureBytes ||
        base64Url.encode(signature) != signatureText) {
      throw const FormatException('Invalid sync signature encoding.');
    }
    return SignedSyncChange._(SyncChange.decode(payload), signature);
  }

  final SyncChange change;
  final Uint8List signature;

  List<String> _wire() => [change.canonical, base64Url.encode(signature)];

  /// This encoding contains cleartext records. Use [SyncEnvelopeCodec] for a
  /// transmission and explicit protected storage for any persisted journal.
  String encode() => jsonEncode(_wire());
}

final class VerifiedSyncChange {
  VerifiedSyncChange._(this.signed, this._trust, this._grant)
    : fingerprint = crypto.sha256
          .convert(utf8.encode(signed.change.canonical))
          .toString();

  final SignedSyncChange signed;
  final SyncTrust _trust;
  final _DeviceGrant _grant;
  final String fingerprint;

  SyncChange get change => signed.change;
}

/// Device grants for one workspace. No network names or devices are trusted
/// automatically. Revocation invalidates old verification handles immediately.
final class SyncTrust {
  SyncTrust(
    this.workspaceId, {
    Iterable<SyncDevicePublicKey> approved = const [],
  }) {
    for (final publicKey in approved) {
      approve(publicKey);
    }
  }

  final SyncWorkspaceId workspaceId;
  final _approved = <String, _DeviceGrant>{};

  Set<String> get approvedDeviceIds => Set.unmodifiable(_approved.keys);

  bool isApproved(String deviceId) => _approved.containsKey(deviceId);

  void approve(SyncDevicePublicKey publicKey) {
    final fingerprint = publicKey.fingerprint;
    if (_approved.containsKey(fingerprint)) return;
    if (_approved.length >= maxSyncDevices) {
      throw const SyncTrustException('The approved device limit was reached.');
    }
    _approved[fingerprint] = _DeviceGrant(publicKey);
  }

  bool revoke(String deviceId) => _approved.remove(deviceId) != null;

  bool accepts(VerifiedSyncChange verified) =>
      identical(verified._trust, this) &&
      identical(_approved[verified.change.dot.deviceId], verified._grant);

  Future<VerifiedSyncChange> verify(SignedSyncChange signed) async {
    final change = signed.change;
    if (change.workspaceId != workspaceId) {
      throw const SyncTrustException(
        'The change belongs to another workspace.',
      );
    }
    final grant = _grant(change.dot.deviceId);
    final verified = await _signatureAlgorithm.verify(
      _signingBytes(change),
      signature: Signature(
        Uint8List.fromList(signed.signature),
        publicKey: grant.publicKey.key,
      ),
    );
    if (!verified) throw const SyncAuthenticationException();
    _ensureGrant(change.dot.deviceId, grant);
    return VerifiedSyncChange._(signed, this, grant);
  }

  _DeviceGrant _grant(String deviceId) =>
      _approved[deviceId] ??
      (throw const SyncTrustException(
        'The device is not approved for this workspace.',
      ));

  void _ensureGrant(String deviceId, _DeviceGrant grant) {
    if (!identical(_approved[deviceId], grant)) {
      throw const SyncTrustException('The device approval changed.');
    }
  }
}

final class _DeviceGrant {
  _DeviceGrant(this.publicKey);

  final SyncDevicePublicKey publicKey;
}

final class SyncTrustException implements Exception {
  const SyncTrustException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class SyncAuthenticationException implements Exception {
  const SyncAuthenticationException();

  @override
  String toString() => 'The sync data could not be authenticated.';
}

Uint8List _signingBytes(SyncChange change) =>
    Uint8List.fromList(utf8.encode('$_signatureDomain${change.canonical}'));

Uint8List _pairingProofBytes(String transcript) {
  if (transcript.length > 4096) {
    throw const FormatException('Invalid pairing transcript length.');
  }
  final bytes = utf8.encode('$_pairingProofDomain$transcript');
  if (bytes.length > 4096) {
    throw const FormatException('Invalid pairing transcript length.');
  }
  return Uint8List.fromList(bytes);
}

/// A dedicated AES key for one approved pair in one workspace. Exchange key
/// material through authenticated pairing and keep it in the host key store.
final class SyncPairKey {
  SyncPairKey._(this._secret);

  factory SyncPairKey.generate() =>
      SyncPairKey._(SecretKeyData.random(length: _pairKeyBytes));

  factory SyncPairKey.fromBytes(List<int> key) => SyncPairKey._(
    SecretKeyData(
      syncFixedBytes(key, _pairKeyBytes, 'pair key'),
      overwriteWhenDestroyed: true,
    ),
  );

  final SecretKeyData _secret;

  String get keyId => crypto.sha256.convert(_secret.bytes).toString();

  Uint8List copyBytesForSecureStorage() => Uint8List.fromList(_secret.bytes);

  void destroy() => _secret.destroy();
}

/// An authenticated progress receipt lets the next manual export continue
/// from the recipient's last saved causal watermark.
final class SyncProgressCodec {
  const SyncProgressCodec();

  static const _prefix = 'easy-progress1:';
  static const _maximumTokenLength = 8192;
  static final _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: _pairKeyBytes);

  Future<String> seal({
    required SyncWorkspaceId workspace,
    required String senderId,
    required String recipientId,
    required SyncPairKey key,
    required SyncVersionVector watermark,
  }) async {
    final context = _progressContext(workspace, senderId, recipientId);
    final derived = await _kdf.deriveKey(secretKey: key._secret, info: context);
    try {
      final sealed = await _encryptionAlgorithm.encrypt(
        utf8.encode(jsonEncode(watermark.counters)),
        secretKey: derived,
        aad: context,
      );
      final token = '$_prefix${base64Url.encode(sealed.concatenation())}';
      if (token.length > _maximumTokenLength) {
        throw const FormatException('Sync progress is too large.');
      }
      return token;
    } finally {
      derived.destroy();
    }
  }

  Future<SyncVersionVector> open({
    required String token,
    required SyncWorkspaceId workspace,
    required String senderId,
    required String recipientId,
    required SyncPairKey key,
  }) async {
    if (token.length > _maximumTokenLength || !token.startsWith(_prefix)) {
      throw const FormatException('Invalid sync progress receipt.');
    }
    final Uint8List bytes;
    try {
      final payload = token.substring(_prefix.length);
      bytes = base64Url.decode(payload);
      if (bytes.length <= _nonceLength + _tagLength ||
          base64Url.encode(bytes) != payload) {
        throw const FormatException('Invalid sync progress receipt.');
      }
    } on FormatException {
      throw const FormatException('Invalid sync progress receipt.');
    }
    final context = _progressContext(workspace, senderId, recipientId);
    final derived = await _kdf.deriveKey(secretKey: key._secret, info: context);
    try {
      final opened = await _encryptionAlgorithm.decrypt(
        SecretBox.fromConcatenation(
          bytes,
          nonceLength: _nonceLength,
          macLength: _tagLength,
        ),
        secretKey: derived,
        aad: context,
      );
      final decoded = syncDecodeJson(
        utf8.decode(opened),
        maxChars: _maximumTokenLength,
        maxDepth: 2,
      );
      if (decoded is! Map<String, dynamic> ||
          decoded.values.any((value) => value is! int)) {
        throw const FormatException('Invalid sync progress watermark.');
      }
      return SyncVersionVector(decoded.cast<String, int>());
    } on SecretBoxAuthenticationError {
      throw const SyncAuthenticationException();
    } finally {
      derived.destroy();
    }
  }

  List<int> _progressContext(
    SyncWorkspaceId workspace,
    String sender,
    String recipient,
  ) {
    if (sender == recipient ||
        !syncMatches(syncDeviceIdPattern, sender) ||
        !syncMatches(syncDeviceIdPattern, recipient)) {
      throw const SyncTrustException(
        'Sync progress requires two approved devices.',
      );
    }
    return utf8.encode(
      'Easy Manual Sync Progress v1\u0000${workspace.value}\t$sender\t$recipient',
    );
  }
}

const _envelopeMagic = 'EASYSYN\u0000';
const _envelopeVersion = 1;
const _tagLength = 16;
const _nonceLength = 12;
const _maximumBatchBytes = 1024 * 1024;
const _workspaceIdLength = 16;
const _peerIdLength = 32;
const _nonceOffset = 9 + _workspaceIdLength + 2 * _peerIdLength;
const _headerLength = _nonceOffset + _nonceLength;

/// AES-256-GCM wire framing for a pair that has already approved each other's
/// keys and established a dedicated secret. The recipient, sender, workspace,
/// nonce and version are authenticated, and every change is independently
/// signed. Transport, key exchange and durable application belong to the host.
final class SyncEnvelopeCodec {
  const SyncEnvelopeCodec();

  static const maximumChanges = 48;
  static const maximumPayloadBytes = _maximumBatchBytes;
  static const maximumBytes = _maximumBatchBytes + _headerLength + _tagLength;

  Future<Uint8List> seal({
    required SyncTrust trust,
    required String senderId,
    required String recipientId,
    required SyncPairKey key,
    required List<VerifiedSyncChange> changes,
  }) async {
    final sender = trust._grant(senderId);
    final recipient = trust._grant(recipientId);
    if (senderId == recipientId) {
      throw const SyncTrustException('A sync envelope requires two devices.');
    }
    if (changes.isEmpty || changes.length > maximumChanges) {
      throw const FormatException('Invalid sync batch size.');
    }
    final batch = List<VerifiedSyncChange>.of(changes);
    final json = StringBuffer('[');
    var batchSize = 1;
    for (final change in batch) {
      if (!trust.accepts(change)) {
        throw const SyncTrustException(
          'A change is outside the approved workspace.',
        );
      }
      final encoded = change.signed.encode();
      batchSize += encoded.length + 1;
      if (batchSize > _maximumBatchBytes) {
        throw const FormatException('Sync batch exceeds its size limit.');
      }
      if (json.length > 1) json.write(',');
      json.write(encoded);
    }
    json.write(']');
    final body = utf8.encode(json.toString());
    if (body.length > _maximumBatchBytes) {
      throw const FormatException('Sync batch exceeds its size limit.');
    }
    final nonce = _encryptionAlgorithm.newNonce();
    final header = _header(trust.workspaceId, senderId, recipientId, nonce);
    final box = await _encryptionAlgorithm.encrypt(
      body,
      secretKey: key._secret,
      aad: header,
      nonce: nonce,
    );
    trust._ensureGrant(senderId, sender);
    trust._ensureGrant(recipientId, recipient);
    if (batch.any((change) => !trust.accepts(change))) {
      throw const SyncTrustException('A device approval changed.');
    }
    final output = BytesBuilder(copy: false)
      ..add(header)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return output.takeBytes();
  }

  Future<List<VerifiedSyncChange>> open({
    required Uint8List envelope,
    required SyncTrust trust,
    required String senderId,
    required String recipientId,
    required SyncPairKey key,
  }) async {
    final sender = trust._grant(senderId);
    final recipient = trust._grant(recipientId);
    if (senderId == recipientId) {
      throw const SyncTrustException('A sync envelope requires two devices.');
    }
    if (envelope.length <= _headerLength + _tagLength ||
        envelope.length > maximumBytes) {
      throw const FormatException('Invalid sync envelope length.');
    }
    final bytes = Uint8List.fromList(envelope);
    if (bytes[8] != _envelopeVersion ||
        !_matchesBytes(bytes, _envelopeMagic.codeUnits)) {
      throw const FormatException('Unsupported sync envelope.');
    }
    final nonce = Uint8List.sublistView(bytes, _nonceOffset, _headerLength);
    final header = Uint8List.sublistView(bytes, 0, _headerLength);
    final expected = _header(trust.workspaceId, senderId, recipientId, nonce);
    for (var index = 0; index < _nonceOffset; index++) {
      if (header[index] != expected[index]) {
        throw const SyncAuthenticationException();
      }
    }
    final tagOffset = bytes.length - _tagLength;
    final box = SecretBox(
      Uint8List.sublistView(bytes, _headerLength, tagOffset),
      nonce: nonce,
      mac: Mac(Uint8List.sublistView(bytes, tagOffset)),
    );
    final List<int> body;
    try {
      body = await _encryptionAlgorithm.decrypt(
        box,
        secretKey: key._secret,
        aad: header,
      );
    } on SecretBoxAuthenticationError {
      throw const SyncAuthenticationException();
    }
    final values = syncDecodeJson(
      utf8.decode(body),
      maxChars: _maximumBatchBytes,
    );
    if (values is! List || values.isEmpty || values.length > maximumChanges) {
      throw const FormatException('Invalid sync batch size.');
    }
    final verified = <VerifiedSyncChange>[];
    for (final value in values) {
      verified.add(await trust.verify(SignedSyncChange._fromWire(value)));
    }
    trust._ensureGrant(senderId, sender);
    trust._ensureGrant(recipientId, recipient);
    if (verified.any((change) => !trust.accepts(change))) {
      throw const SyncTrustException('A device approval changed.');
    }
    return List.unmodifiable(verified);
  }

  static Uint8List _header(
    SyncWorkspaceId workspace,
    String sender,
    String recipient,
    List<int> nonce,
  ) => Uint8List.fromList([
    ..._envelopeMagic.codeUnits,
    _envelopeVersion,
    ...syncHexBytes(workspace.value),
    ...syncHexBytes(sender),
    ...syncHexBytes(recipient),
    ...nonce,
  ]);

  static bool _matchesBytes(List<int> bytes, List<int> prefix) {
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }
}
