import 'dart:convert';
import 'dart:typed_data';

import 'package:easy/sync/sync_pairing.dart';
import 'package:easy/sync/workspace_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SyncDeviceIdentity first;
  late SyncDeviceIdentity second;
  late SyncWorkspaceId workspace;
  late DateTime clock;

  setUp(() async {
    first = await SyncDeviceIdentity.generate();
    second = await SyncDeviceIdentity.generate();
    workspace = SyncWorkspaceId.generate();
    clock = DateTime.utc(2026, 11, 24, 3);
  });

  tearDown(() {
    first.destroy();
    second.destroy();
  });

  Future<SyncPairingInvitation> invite() => SyncPairingInvitation.create(
    workspaceId: workspace,
    identity: first,
    now: () => clock,
  );

  Future<SyncPairingResponse> respond(String code) =>
      respondToSyncPairingInvitation(
        invitation: code,
        identity: second,
        now: () => clock,
      );

  test('manual ceremony binds the workspace, fingerprints and both comparison approvals', () async {
    final invitation = await invite();
    addTearDown(invitation.cancel);
    final summary = await inspectSyncPairingInvitation(
      invitation.code,
      now: () => clock,
    );
    expect(summary.workspaceId, workspace);
    expect(summary.sender.fingerprint, first.deviceId);
    expect(summary.expiresAt, clock.add(const Duration(minutes: 5)));

    final response = await respond(invitation.code);
    final joining = response.review;
    addTearDown(joining.cancel);
    final inviting = await invitation.receiveResponse(response.code);
    addTearDown(inviting.cancel);
    expect(inviting.peer.fingerprint, second.deviceId);
    expect(joining.peer.fingerprint, first.deviceId);
    expect(inviting.comparisonCode, matches(r'^[0-9A-Z]{4}-[0-9A-Z]{4}$'));
    expect(inviting.comparisonCode, joining.comparisonCode);
    final approvalFromFirst = await inviting.confirmComparison(
      joining.comparisonCode,
    );
    await expectLater(
      joining.finish(approvalFromFirst),
      throwsA(isA<SyncPairingException>()),
    );
    await expectLater(
      inviting.finish(approvalFromFirst),
      throwsA(isA<SyncPairingException>()),
    );

    final approvalFromSecond = await joining.confirmComparison(
      inviting.comparisonCode,
    );
    final firstPair = await inviting.finish(approvalFromSecond);
    final secondPair = await joining.finish(approvalFromFirst);
    expect(firstPair.localDeviceId, first.deviceId);
    expect(secondPair.localDeviceId, second.deviceId);
    expect(firstPair.workspaceId, workspace);
    final firstKey = firstPair.takeKey();
    final secondKey = secondPair.takeKey();
    addTearDown(firstKey.destroy);
    addTearDown(secondKey.destroy);
    expect(
      firstKey.copyBytesForSecureStorage(),
      secondKey.copyBytesForSecureStorage(),
    );
    expect(() => firstPair.takeKey(), throwsA(isA<SyncPairingException>()));
    expect(() => invitation.code, throwsA(isA<SyncPairingException>()));
    await expectLater(
      invitation.receiveResponse(response.code),
      throwsA(isA<SyncPairingException>()),
    );
    await expectLater(
      inviting.finish(approvalFromSecond),
      throwsA(isA<SyncPairingException>()),
    );
  });

  test(
    'tampered invitations and responses fail before a device can be approved',
    () async {
      final invitation = await invite();
      addTearDown(invitation.cancel);
      final code = invitation.code;
      final alteredSecret = _edit(
        code,
        (fields) => _changeByte(fields, 'secret'),
      );
      final alteredWorkspace = _edit(
        code,
        (fields) => fields['workspace'] = SyncWorkspaceId.generate().value,
      );
      for (final invalid in [alteredSecret, alteredWorkspace]) {
        await expectLater(
          respond(invalid),
          throwsA(isA<SyncPairingException>()),
        );
      }
      final otherOffer = await invite();
      addTearDown(otherOffer.cancel);
      final otherResponse = await respond(otherOffer.code);
      addTearDown(otherResponse.review.cancel);
      await expectLater(
        invitation.receiveResponse(otherResponse.code),
        throwsA(isA<SyncPairingException>()),
      );
      final reply = await respond(code);
      addTearDown(reply.review.cancel);
      final alteredResponse = _edit(
        reply.code,
        (fields) => _changeByte(fields, 'mac'),
      );
      await expectLater(
        invitation.receiveResponse(alteredResponse),
        throwsA(isA<SyncPairingException>()),
      );
      await expectLater(
        invitation.receiveResponse(reply.code),
        throwsA(isA<SyncPairingException>()),
      );
    },
  );

  test('confirmation requires the matching transcript and the peer identity signature', () async {
    final invitation = await invite();
    final reply = await respond(invitation.code);
    final review = await invitation.receiveResponse(reply.code);
    addTearDown(review.cancel);
    addTearDown(reply.review.cancel);
    final local = await review.confirmComparison(reply.review.comparisonCode);
    final remote = await reply.review.confirmComparison(review.comparisonCode);
    final other = await invite();
    final otherReply = await respond(other.code);
    final otherReview = await other.receiveResponse(otherReply.code);
    addTearDown(otherReview.cancel);
    addTearDown(otherReply.review.cancel);
    final unrelated = await otherReply.review.confirmComparison(
      otherReview.comparisonCode,
    );
    for (final invalid in [
      local,
      unrelated,
      _edit(remote, (fields) => _changeByte(fields, 'proof')),
    ]) {
      await expectLater(
        review.finish(invalid),
        throwsA(isA<SyncPairingException>()),
      );
    }
    final approved = await review.finish(remote);
    approved.discard();
  });

  test(
    'expired, abandoned, oversize and same-device invitations cannot complete',
    () async {
      final invitation = await invite();
      final code = invitation.code;
      final response = await respond(code);
      final review = await invitation.receiveResponse(response.code);
      addTearDown(response.review.cancel);
      addTearDown(review.cancel);
      await expectLater(
        respondToSyncPairingInvitation(
          invitation: code,
          identity: first,
          now: () => clock,
        ),
        throwsA(isA<SyncPairingException>()),
      );
      await expectLater(respond('$code${'A' * 5000}'), throwsFormatException);
      clock = clock.add(const Duration(minutes: 5));
      expect(() => review.comparisonCode, throwsA(isA<SyncPairingException>()));
      await expectLater(respond(code), throwsA(isA<SyncPairingException>()));
      final cancelled = await invite();
      cancelled.cancel();
      expect(() => cancelled.code, throwsA(isA<SyncPairingException>()));
    },
  );

  test('a mismatch closes the local comparison and cannot later approve a valid receipt', () async {
    final invitation = await invite();
    final response = await respond(invitation.code);
    final review = await invitation.receiveResponse(response.code);
    addTearDown(response.review.cancel);
    final correct = await response.review.confirmComparison(
      review.comparisonCode,
    );
    await expectLater(
      review.confirmComparison('wrong'),
      throwsA(isA<SyncPairingException>()),
    );
    await expectLater(
      review.finish(correct),
      throwsA(isA<SyncPairingException>()),
    );
  });
}

String _edit(String code, void Function(Map<String, dynamic>) change) {
  final separator = code.indexOf(':') + 1;
  final input = jsonDecode(
    utf8.decode(base64Url.decode(code.substring(separator))),
  ) as Map<String, dynamic>;
  change(input);
  return '${code.substring(0, separator)}${base64Url.encode(utf8.encode(jsonEncode(input)))}';
}

void _changeByte(Map<String, dynamic> fields, String name) {
  final bytes = Uint8List.fromList(base64Url.decode(fields[name] as String));
  bytes[0] ^= 1;
  fields[name] = base64Url.encode(bytes);
}
