import 'package:material_ui/material_ui.dart';

import '../../ui_theme.dart';
import '../manual_sync_workspace.dart';
import '../manual_sync_contracts.dart';
import 'manual_sync_ui.dart';

class ManualPairingPage extends StatefulWidget {
  const ManualPairingPage({
    required this.workspace,
    required this.enable,
    required this.copyToken,
    required this.pasteToken,
    super.key,
  });

  final ManualSyncWorkspace? workspace;
  final Future<ManualSyncWorkspace> Function(SyncWorkspaceId?) enable;
  final Future<void> Function(String) copyToken;
  final Future<String?> Function() pasteToken;

  @override
  State<ManualPairingPage> createState() => _ManualPairingPageState();
}

class _ManualPairingPageState extends State<ManualPairingPage> {
  late ManualSyncWorkspace? _workspace = widget.workspace;
  SyncPairingInvitation? _invitation;
  ({String token, SyncPairingOfferSummary summary})? _offer;
  SyncPairingReview? _review;
  String? _response;
  String? _approval;
  PairedSyncDevice? _confirmed;
  ({String message, bool error})? _feedback;
  var _working = false;

  @override
  void dispose() {
    _discard();
    super.dispose();
  }

  void _discard() {
    _invitation?.cancel();
    _review?.cancel();
    _confirmed?.discard();
    _invitation = null;
    _offer = null;
    _review = null;
    _confirmed = null;
    _response = null;
    _approval = null;
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_working) return;
    setState(() {
      _working = true;
      _feedback = null;
    });
    try {
      await work();
    } on ManualSyncTransferCancelled {
      // A cancelled unlock preserves the current pairing step.
    } catch (error) {
      _inform(
        manualSyncError(error, 'The pairing could not continue.'),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _inform(String text, {bool error = false}) {
    if (mounted) setState(() => _feedback = (message: text, error: error));
  }

  Future<void> _create() => _run(() async {
    final workspace = _workspace ?? await widget.enable(null);
    final invitation = await workspace.createInvitation();
    if (!mounted) {
      invitation.cancel();
      return;
    }
    setState(() {
      _workspace = workspace;
      _invitation = invitation;
    });
  });

  Future<void> _inspect() => _run(() async {
    final token = await requestManualSyncToken(
      context,
      title: 'Enter invitation',
      label: 'Invitation token',
      paste: widget.pasteToken,
    );
    if (token == null) return;
    final summary = await inspectSyncPairingInvitation(token);
    if (mounted) setState(() => _offer = (token: token, summary: summary));
  });

  Future<void> _respond() => _run(() async {
    final offer = _offer!;
    final workspace =
        _workspace ?? await widget.enable(offer.summary.workspaceId);
    final response = await workspace.respond(offer.token);
    if (!mounted) {
      response.review.cancel();
      return;
    }
    setState(() {
      _workspace = workspace;
      _offer = null;
      _response = response.code;
      _review = response.review;
    });
  });

  Future<void> _receive() => _run(() async {
    final token = await requestManualSyncToken(
      context,
      title: 'Enter response',
      label: 'Response token',
      paste: widget.pasteToken,
    );
    if (token == null) return;
    final review = await _invitation!.receiveResponse(token);
    if (!mounted) {
      review.cancel();
      return;
    }
    setState(() {
      _invitation = null;
      _review = review;
    });
  });

  Future<void> _compare() => _run(() async {
    final review = _review!;
    final token = await requestManualSyncToken(
      context,
      title: 'Confirm matching codes',
      label: 'Code shown on the other device',
      maximumLength: 12,
      action: 'Confirm code',
    );
    if (token == null) return;
    final approval = await review.confirmComparison(token);
    if (mounted) setState(() => _approval = approval);
  });

  Future<void> _complete() => _run(() async {
    final token = await requestManualSyncToken(
      context,
      title: 'Enter peer approval',
      label: 'Approval token',
      paste: widget.pasteToken,
    );
    if (token == null) return;
    final confirmed = await _review!.finish(token);
    if (!mounted) {
      confirmed.discard();
      return;
    }
    setState(() => _confirmed = confirmed);
    await _savePair();
  });

  Future<void> _savePair() async {
    final workspace = _workspace!;
    final current = await workspace.status();
    await workspace.approvePair(
      _confirmed!,
      expectedRevision: current.revision,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copy(String Function() token) => _run(() async {
    await widget.copyToken(token());
    _inform('Code copied. Share it with the other device.');
  });

  String? _comparisonCode() {
    try {
      return _review?.comparisonCode;
    } on SyncPairingException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    final invitation = _invitation;
    final review = _review;
    final response = _response;
    final approval = _approval;
    final confirmed = _confirmed;
    final comparison = confirmed == null && approval == null
        ? _comparisonCode()
        : null;
    final active = invitation != null || offer != null || review != null;
    return ManualSyncFrame(
      title: 'Pair a device',
      canPop: !_working,
      child: ListView(
        padding: manualSyncPadding,
        children: [
          if (!active) ...[
            const Text(
              'Pair with the person holding your other device.',
              style: sectionHeadingStyle,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_workspace != null)
                  FilledButton(
                    onPressed: _working ? null : _create,
                    child: const Text('Create invitation'),
                  ),
                OutlinedButton(
                  onPressed: _working ? null : _inspect,
                  child: const Text('Use an invitation'),
                ),
              ],
            ),
          ] else if (confirmed != null) ...[
            _PairStage(
              title: 'Pairing confirmed',
              body: 'Both devices approved the same exchange.',
              buttons: [
                FilledButton(
                  onPressed: _working ? null : () => _run(_savePair),
                  child: const Text('Save pairing'),
                ),
              ],
            ),
          ] else if (approval != null) ...[
            _PairStage(
              title: 'Exchange approvals',
              body: 'Copy your approval, then enter the approval from the other device.',
              buttons: [
                OutlinedButton(
                  onPressed: _working ? null : () => _copy(() => approval),
                  child: const Text('Copy approval'),
                ),
                FilledButton(
                  onPressed: _working ? null : _complete,
                  child: const Text('Enter peer approval'),
                ),
              ],
            ),
          ] else if (review != null) ...[
            if (response != null) ...[
              _PairStage(
                title: 'Send the response',
                body: 'Share your response with the device that opened the invitation.',
                buttons: [
                  OutlinedButton(
                    onPressed: _working ? null : () => _copy(() => response),
                    child: const Text('Copy response'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            _PairStage(
              title: 'Compare both screens',
              body: comparison == null
                  ? 'Start a new invitation to compare the codes again.'
                  : 'Check this fingerprint and compare the code on the other device.',
              detail: [
                SelectableText(
                  manualFingerprint(review.peer.fingerprint),
                  style: contentMetadataStyle,
                ),
                if (comparison != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    comparison,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 31,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ],
              buttons: [
                FilledButton(
                  onPressed: _working || comparison == null ? null : _compare,
                  child: const Text('Compare codes'),
                ),
              ],
            ),
          ] else if (offer != null) ...[
            _PairStage(
              title: 'Check the inviting device',
              body: 'Verify this fingerprint on the other screen before creating a response.',
              detail: [
                SelectableText(
                  manualFingerprint(offer.summary.sender.fingerprint),
                  style: contentMetadataStyle,
                ),
              ],
              buttons: [
                FilledButton(
                  onPressed: _working ? null : _respond,
                  child: const Text('Create response'),
                ),
              ],
            ),
          ] else if (invitation != null) ...[
            _PairStage(
              title: 'Share this invitation',
              body: 'Share the code directly with the other device. It expires in five minutes.',
              buttons: [
                OutlinedButton(
                  onPressed: _working
                      ? null
                      : () => _copy(() => invitation.code),
                  child: const Text('Copy invitation'),
                ),
                FilledButton(
                  onPressed: _working ? null : _receive,
                  child: const Text('Enter response'),
                ),
              ],
            ),
          ],
          if (_feedback case final feedback?) ...[
            const SizedBox(height: 13),
            ManualSyncFeedback(feedback.message, error: feedback.error),
          ],
          if (active)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: _working
                    ? null
                    : () => setState(() {
                        _discard();
                        _feedback = null;
                      }),
                child: const Text('Start over'),
              ),
            ),
        ],
      ),
    );
  }
}

class _PairStage extends StatelessWidget {
  const _PairStage({
    required this.title,
    required this.body,
    required this.buttons,
    this.detail = const [],
  });

  final String title;
  final String body;
  final List<Widget> detail;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => ManualSyncSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: sectionHeadingStyle),
        const SizedBox(height: 7),
        Text(body, style: contentMetadataStyle),
        if (detail.isNotEmpty) ...[const SizedBox(height: 12), ...detail],
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: buttons),
      ],
    ),
  );
}
