import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'manual_sync_contracts.dart';
import 'manual_sync_workspace.dart';
import 'src/manual_sync_pairing_page.dart';
import 'src/manual_sync_peer_page.dart';
import 'src/manual_sync_ui.dart';

export 'manual_sync_contracts.dart';

class ManualSyncPage extends StatefulWidget {
  const ManualSyncPage({required this.host, this.projector, super.key});

  final ManualSyncPageHost host;
  final ManualSyncProjector? projector;

  @override
  State<ManualSyncPage> createState() => _ManualSyncPageState();
}

typedef _ConfiguredSync = ({
  ManualSyncWorkspace workspace,
  SyncJournalStatus status,
});

class _ManualSyncPageState extends State<ManualSyncPage> {
  late Future<_ConfiguredSync?> _configured = _open();
  String? _error;
  var _working = false;

  Future<_ConfiguredSync?> _open() async {
    final workspace = await widget.host.openConfigured();
    return workspace == null
        ? null
        : (workspace: workspace, status: await workspace.status());
  }

  void _refresh() {
    final next = _open();
    setState(() {
      _configured = next;
    });
  }

  Future<void> _enable() async {
    setState(() {
      _error = null;
      _working = true;
    });
    try {
      final workspace = await widget.host.enable(null);
      final status = await workspace.status();
      if (mounted) {
        setState(() {
          _configured = Future.value((workspace: workspace, status: status));
        });
      }
    } catch (error) {
      if (mounted) {
        _error = manualSyncError(error, 'Manual sync could not be enabled.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pair(ManualSyncWorkspace? workspace) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ManualPairingPage(
          workspace: workspace,
          enable: widget.host.enable,
          copyToken: widget.host.copyToken,
          pasteToken: widget.host.pasteToken,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _device(ManualSyncWorkspace workspace, String peerId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ManualSyncPeerPage(
          workspace: workspace,
          peerId: peerId,
          host: widget.host,
          projector: widget.projector,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => ManualSyncFrame(
    title: 'Manual sync',
    canPop: !_working,
    child: FutureBuilder(
      future: _configured,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final configured = snapshot.data;
        if (snapshot.hasError) {
          return ListView(
            padding: manualSyncPadding,
            children: [
              ManualSyncFeedback(
                manualSyncError(
                  snapshot.error,
                  'The configured sync workspace could not be opened.',
                ),
                error: true,
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _refresh,
                  child: const Text('Try again'),
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: manualSyncPadding,
          children: [
            if (configured == null) ...[
              const ManualSyncSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('On this device', style: sectionHeadingStyle),
                    SizedBox(height: 6),
                    Text(
                      'Pair in person and exchange encrypted change files when you choose.',
                      style: contentMetadataStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _working ? null : _enable,
                    child: const Text('Enable manual sync'),
                  ),
                  TextButton(
                    onPressed: _working ? null : () => _pair(null),
                    child: const Text('Join a device'),
                  ),
                ],
              ),
            ] else ...[
              ManualSyncSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('This device', style: sectionHeadingStyle),
                    const SizedBox(height: 7),
                    SelectableText(
                      manualFingerprint(configured.status.localDeviceId),
                      style: contentMetadataStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  onPressed: () => _pair(configured.workspace),
                  icon: const Icon(Icons.add_rounded, size: 19),
                  label: const Text('Pair a device'),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Paired devices', style: sectionHeadingStyle),
              const SizedBox(height: 10),
              if (configured.status.approvedPairKeyIds.isEmpty)
                const Text(
                  'No paired devices yet.',
                  style: contentMetadataStyle,
                ),
              for (final peer in configured.status.approvedPairKeyIds.keys) ...[
                ManualSyncSurface(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(
                      Icons.devices_other_rounded,
                      color: accent,
                    ),
                    title: const Text(
                      'Paired device',
                      style: contentTitleStyle,
                    ),
                    subtitle: Text(
                      manualFingerprint(peer),
                      style: contentMetadataStyle,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _device(configured.workspace, peer),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              ManualSyncFeedback(error, error: true),
            ],
          ],
        );
      },
    ),
  );
}
