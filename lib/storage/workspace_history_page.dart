import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'workspace_store.dart';

class WorkspaceHistoryPage extends StatefulWidget {
  const WorkspaceHistoryPage({
    required this.store,
    required this.onRestored,
    super.key,
  });

  final WorkspaceHistoryStore store;
  final Future<void> Function(WorkspaceRevision) onRestored;

  @override
  State<WorkspaceHistoryPage> createState() => _WorkspaceHistoryPageState();
}

class _WorkspaceHistoryPageState extends State<WorkspaceHistoryPage> {
  late Future<List<WorkspaceHistoryPoint>> _points = widget.store.listHistory();
  String? _message;
  var _working = false;

  void _reload() {
    final points = widget.store.listHistory();
    setState(() {
      _points = points;
    });
  }

  Future<void> _name(WorkspaceHistoryPoint current) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _VersionNameDialog(initialName: current.name),
    );
    if (!mounted || name == null) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await widget.store.nameHistoryPoint(
        name,
        expectedRevision: current.revision,
      );
      if (mounted) _reload();
    } on WorkspaceRevisionConflict {
      if (mounted) {
        _message =
            'The workspace changed. Choose a name for the current version.';
        _reload();
      }
    } catch (error) {
      if (mounted) {
        _message = _historyError(error, 'The version could not be named.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _review(WorkspaceHistoryPoint point) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ReviewHistoryPoint(
          store: widget.store,
          point: point,
          onRestored: widget.onRestored,
        ),
      ),
    );
    if (!mounted) return;
    _reload();
    if (changed == true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Workspace restored.')));
    }
  }

  @override
  Widget build(BuildContext context) => _HistoryFrame(
    title: 'Version history',
    child: FutureBuilder(
      future: _points,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _HistoryLoading();
        }
        final points = snapshot.data;
        if (points == null) {
          return _HistoryMessage(
            'Saved versions could not be opened.',
            retry: _reload,
          );
        }
        if (points.isEmpty) {
          return const _HistoryMessage('Saved changes appear here.');
        }
        final latest = points.first;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text(
              'Choose a saved version to review changes.',
              style: contentMetadataStyle,
            ),
            const SizedBox(height: 14),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _working ? null : () => _name(latest),
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: Text(
                  latest.name == null
                      ? 'Name current version'
                      : 'Rename current version',
                ),
              ),
            ),
            if (_message case final message?) ...[
              const SizedBox(height: 12),
              _HistoryStatus(message),
            ],
            const SizedBox(height: 16),
            _HistorySurface(
              child: Column(
                children: [
                  for (final (index, point) in points.indexed) ...[
                    if (index > 0) const Divider(),
                    ListTile(
                      leading: Icon(
                        point.name != null
                            ? Icons.bookmark_outline_rounded
                            : Icons.history_rounded,
                        color: accent,
                      ),
                      title: Text(
                        point.name ??
                            (index == 0
                                ? 'Current workspace'
                                : _historyDate(context, point)),
                        style: contentTitleStyle,
                      ),
                      subtitle: index == 0 || point.name != null
                          ? Text(
                              _historyDate(context, point),
                              style: contentMetadataStyle,
                            )
                          : null,
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: muted,
                      ),
                      enabled: !_working,
                      onTap: _working ? null : () => _review(point),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _ReviewHistoryPoint extends StatefulWidget {
  const _ReviewHistoryPoint({
    required this.store,
    required this.point,
    required this.onRestored,
  });

  final WorkspaceHistoryStore store;
  final WorkspaceHistoryPoint point;
  final Future<void> Function(WorkspaceRevision) onRestored;

  @override
  State<_ReviewHistoryPoint> createState() => _ReviewHistoryPointState();
}

class _ReviewHistoryPointState extends State<_ReviewHistoryPoint> {
  late Future<WorkspaceHistoryDiff> _initial = widget.store.diffHistoryPoint(
    widget.point.revision,
  );
  final _additional = <WorkspaceHistoryRecordChange>[];
  final _selected = <WorkspaceHistoryRecordKey>{};
  String? _message;
  var _working = false;
  var _unnamed = false;

  void _refresh() {
    setState(() {
      _selected.clear();
      _additional.clear();
      _initial = widget.store.diffHistoryPoint(widget.point.revision);
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await operation();
    } on WorkspaceRevisionConflict {
      if (mounted) {
        _message = 'The workspace changed. Review the updated changes.';
        _refresh();
      }
    } catch (error) {
      if (mounted) {
        _message = _historyError(error, 'The version could not be restored.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _loadMore(WorkspaceHistoryDiff first) => _run(() async {
    final page = await widget.store.diffHistoryPoint(
      first.sourceRevision,
      offset: first.changes.length + _additional.length,
      expectedRevision: first.expectedRevision,
    );
    if (mounted) setState(() => _additional.addAll(page.changes));
  });

  Future<void> _removeName(WorkspaceHistoryDiff diff) => _run(() async {
    final confirmed = await _confirmHistoryAction(
      context,
      title: 'Remove the version name?',
      explanation: 'Easy will keep this version according to its usual history schedule.',
      action: 'Remove name',
    );
    if (!mounted || !confirmed) return;
    await widget.store.removeHistoryPointName(
      diff.sourceRevision,
      expectedRevision: diff.expectedRevision,
    );
    if (mounted) setState(() => _unnamed = true);
  });

  Future<void> _restore(
    WorkspaceHistoryDiff diff, {
    required bool whole,
  }) => _run(() async {
    final point = whole
        ? await widget.store.previewHistoryPoint(diff.sourceRevision)
        : null;
    final selected = whole
        ? null
        : await widget.store.previewHistorySelection(
            sourceRevision: diff.sourceRevision,
            expectedRevision: diff.expectedRevision,
            records: Set.of(_selected),
          );
    if (!mounted) return;
    final removals =
        selected?.changes
            .where(
              (change) =>
                  change.reversion == WorkspaceHistoryReversion.removeAdded,
            )
            .length ??
        0;
    final count = selected?.changes.length ?? 0;
    final confirmed = await _confirmHistoryAction(
      context,
      title: whole
          ? 'Restore the whole version?'
          : 'Restore ${_plural(count, 'record')}?',
      explanation: whole
          ? 'This replaces your saved Easy records and workspace settings. Easy saves the current workspace as a recovery point first.'
          : '${removals > 0 ? '${_plural(removals, 'selected record')} will be removed. ' : ''}'
                'Easy saves the current workspace as a recovery point first.',
      action: whole ? 'Restore version' : 'Restore records',
    );
    if (!mounted || !confirmed) return;
    final restored = await widget.store.restoreBackup(
      point ?? selected!.backup,
      expectedRevision: diff.expectedRevision,
    );
    if (!mounted) return;
    if (restored.revision == diff.expectedRevision) {
      _message = 'The workspace already matches this version.';
      return;
    }
    try {
      await widget.onRestored(restored);
    } catch (_) {
      if (mounted) {
        _message = 'Records were restored. Reopen Easy to load the workspace.';
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  });

  @override
  Widget build(BuildContext context) => _HistoryFrame(
    title: 'Review version',
    canPop: !_working,
    child: FutureBuilder(
      future: _initial,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _HistoryLoading();
        }
        final diff = snapshot.data;
        if (diff == null) {
          return _HistoryMessage(
            _historyError(snapshot.error, 'This version could not be opened.'),
            retry: _refresh,
          );
        }
        final visible = [...diff.changes, ..._additional];
        final point = widget.point;
        final name = _unnamed ? null : point.name;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                children: [
                  Text(
                    name ?? _historyDate(context, point),
                    style: sectionHeadingStyle,
                  ),
                  if (name != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      _historyDate(context, point),
                      style: contentMetadataStyle,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    diff.totalChanges == 0
                        ? 'No individual record changes.'
                        : 'Select the records you want to restore.',
                    style: contentMetadataStyle,
                  ),
                  if (_message case final message?) ...[
                    const SizedBox(height: 12),
                    _HistoryStatus(message),
                  ],
                  const SizedBox(height: 16),
                  if (visible.isNotEmpty)
                    _HistorySurface(
                      child: Column(
                        children: [
                          for (final (index, change) in visible.indexed) ...[
                            if (index > 0) const Divider(),
                            CheckboxListTile(
                              key: ValueKey(change.key),
                              title: Text(
                                change.title,
                                style: contentTitleStyle,
                              ),
                              subtitle: Text(
                                _changeLabel(change),
                                style: contentMetadataStyle,
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _selected.contains(change.key),
                              onChanged: _working
                                  ? null
                                  : (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(change.key);
                                      } else {
                                        _selected.remove(change.key);
                                      }
                                    }),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (visible.length < diff.totalChanges)
                    TextButton(
                      onPressed: _working ? null : () => _loadMore(diff),
                      child: const Text('Show more changes'),
                    ),
                  if (name != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: _working ? null : () => _removeName(diff),
                        child: const Text('Remove version name'),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed:
                          _working ||
                              diff.sourceRevision == diff.expectedRevision
                          ? null
                          : () => _restore(diff, whole: true),
                      child: const Text('Restore whole version'),
                    ),
                    FilledButton(
                      onPressed: _working || _selected.isEmpty
                          ? null
                          : () => _restore(diff, whole: false),
                      child: Text(
                        _selected.isEmpty
                            ? 'Review selection'
                            : 'Review ${_plural(_selected.length, 'record')}',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _VersionNameDialog extends StatefulWidget {
  const _VersionNameDialog({this.initialName});

  final String? initialName;

  @override
  State<_VersionNameDialog> createState() => _VersionNameDialogState();
}

class _VersionNameDialogState extends State<_VersionNameDialog> {
  late final _name = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Name this version'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(
        labelText: 'Version name',
        counterText: '',
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty ? null : _submit,
        child: const Text('Save name'),
      ),
    ],
  );
}

class _HistoryFrame extends StatelessWidget {
  const _HistoryFrame({
    required this.title,
    required this.child,
    this.canPop = true,
  });

  final String title;
  final Widget child;
  final bool canPop;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    child: Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: paper,
        surfaceTintColor: paper,
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    ),
  );
}

class _HistorySurface extends StatelessWidget {
  const _HistorySurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: raisedPaper,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: contentSurfaceRadius,
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _HistoryLoading extends StatelessWidget {
  const _HistoryLoading();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox.square(
      dimension: 22,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage(this.message, {this.retry});

  final String message;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      _HistoryStatus(message),
      if (retry != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: retry,
            child: const Text('Reload versions'),
          ),
        ),
    ],
  );
}

class _HistoryStatus extends StatelessWidget {
  const _HistoryStatus(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(message, style: contentMetadataStyle),
  );
}

Future<bool> _confirmHistoryAction(
  BuildContext context, {
  required String title,
  required String explanation,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(explanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

String _historyDate(BuildContext context, WorkspaceHistoryPoint point) {
  final date = point.recordedAt.toLocal();
  final translations = MaterialLocalizations.of(context);
  final time = translations.formatTimeOfDay(
    TimeOfDay.fromDateTime(date),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return '${translations.formatShortDate(date)} · $time';
}

String _changeLabel(WorkspaceHistoryRecordChange change) {
  final recordType = switch (change.key.kind) {
    WorkspaceHistoryRecordKind.task => 'Task',
    WorkspaceHistoryRecordKind.event => 'Calendar event',
    WorkspaceHistoryRecordKind.note => 'Note',
    WorkspaceHistoryRecordKind.capture => 'Capture',
    WorkspaceHistoryRecordKind.gymSession => 'Gym session',
    WorkspaceHistoryRecordKind.workoutPlan => 'Workout plan',
    WorkspaceHistoryRecordKind.meal => 'Meal',
    WorkspaceHistoryRecordKind.food => 'Saved food',
    WorkspaceHistoryRecordKind.activity => 'Activity',
    WorkspaceHistoryRecordKind.routine => 'Routine',
  };
  final action = switch (change.reversion) {
    WorkspaceHistoryReversion.recoverMissing => 'Restore missing record',
    WorkspaceHistoryReversion.restorePrevious => 'Use earlier version',
    WorkspaceHistoryReversion.removeAdded => 'Remove from workspace',
  };
  return '$recordType · $action';
}

String _plural(int count, String word) =>
    '$count $word${count == 1 ? '' : 's'}';

String _historyError(Object? error, String fallback) =>
    error is WorkspaceStoreException ? error.message : fallback;
