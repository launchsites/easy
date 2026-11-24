part of 'manual_sync_peer_page.dart';

class _OutgoingReview extends StatefulWidget {
  const _OutgoingReview({required this.workspace, required this.outgoing});

  final ManualSyncWorkspace workspace;
  final ManualSyncOutgoing outgoing;

  @override
  State<_OutgoingReview> createState() => _OutgoingReviewState();
}

class _OutgoingReviewState extends State<_OutgoingReview> {
  final _search = TextEditingController();
  final _selected = <SyncRecordKey>{};
  ManualSyncOutgoingPreview? _preview;
  String? _error;
  bool _busy = true;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _stale = false;
      _error = null;
      _selected.clear();
    });
    try {
      final preview = await widget.outgoing.previewOutgoing(
        sync: widget.workspace,
        query: _search.text,
      );
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      _stale = true;
      _error = manualSyncError(error, 'The saved records could not be loaded.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stageRecords() async {
    final preview = _preview;
    if (_busy || preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await widget.outgoing.stageOutgoing(
        preview,
        selected: Set.unmodifiable(_selected),
      );
      if (mounted) Navigator.of(context).pop(count);
    } on WorkspaceRevisionConflict {
      _stale = true;
      _error =
          'The workspace changed. Refresh to review the saved records again.';
    } on SyncJournalRevisionConflict {
      _stale = true;
      _error =
          'The journal changed. Refresh to review the saved records again.';
    } catch (error) {
      _error = manualSyncError(error, 'These records could not be staged.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ManualSyncFrame(
    title: 'Choose records',
    canPop: !_busy,
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: manualSyncPadding,
            children: [
              const Text(
                'Stage tasks, events and notes for your paired devices. Export creates an encrypted file with the journal changes this device is missing.',
                style: contentMetadataStyle,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _search,
                enabled: !_busy,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _load(),
                maxLength: 100,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: 'Find saved records',
                  suffixIcon: IconButton(
                    tooltip: 'Search saved records',
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                ManualSyncFeedback(error, error: true),
              ],
              if (_stale)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _load,
                    child: const Text('Refresh records'),
                  ),
                ),
              if (_busy && _preview == null)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_preview case final preview?) ...[
                if (preview.hasMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Search for a specific record to see more matches.',
                      style: contentMetadataStyle,
                    ),
                  ),
                if (preview.records.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No saved tasks, events or notes match this search.',
                      style: contentMetadataStyle,
                    ),
                  ),
                for (final record in preview.records)
                  CheckboxListTile(
                    key: ValueKey(record.key),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(record.title, style: contentTitleStyle),
                    subtitle: Text(record.details, style: contentMetadataStyle),
                    value: _selected.contains(record.key),
                    onChanged:
                        _busy ||
                            _stale ||
                            (_selected.length >= maxLocalSyncBatchChanges &&
                                !_selected.contains(record.key))
                        ? null
                        : (value) => setState(() {
                            if (value ?? false) {
                              _selected.add(record.key);
                            } else {
                              _selected.remove(record.key);
                            }
                          }),
                  ),
              ],
            ],
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 11, 20, 15),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              onPressed: _busy || _stale || _selected.isEmpty
                  ? null
                  : _stageRecords,
              child: Text(
                _selected.isEmpty
                    ? 'Stage records'
                    : 'Stage ${_records(_selected.length)}',
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
