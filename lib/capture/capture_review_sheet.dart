import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import '../workspace_data.dart' show spaceName;
import 'capture_archive.dart';
import 'capture_interpreter.dart';

class CaptureReviewRequest {
  const CaptureReviewRequest(this.text);

  final String text;
}

typedef ReviewCaptureText = Future<CaptureReview> Function({
  String? draftId,
  required String text,
});
typedef ApplyCaptureItems = Future<String?> Function(
  CaptureReview,
  List<CaptureProposal>,
);

class CaptureReviewSheet extends StatefulWidget {
  const CaptureReviewSheet({
    required this.initialText,
    required this.drafts,
    required this.onReview,
    required this.onApply,
    super.key,
  });

  final String initialText;
  final List<CaptureArchiveEntry> drafts;
  final ReviewCaptureText onReview;
  final ApplyCaptureItems onApply;

  @override
  State<CaptureReviewSheet> createState() => _CaptureReviewSheetState();
}

class _CaptureReviewSheetState extends State<CaptureReviewSheet> {
  late final _controller = TextEditingController(text: widget.initialText);
  CaptureReview? _review;
  String? _draftId;
  String? _error;
  var _working = false;
  final _selected = <CaptureProposal>{};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reviewText() async {
    final text = _controller.text.trim();
    if (_working || text.isEmpty) return;
    setState(() {
      _working = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      final review = await widget.onReview(draftId: _draftId, text: text);
      if (!mounted) return;
      setState(() {
        _draftId = review.input.id;
        _review = review;
        _selected
          ..clear()
          ..addAll(review.proposals.where((proposal) => proposal.isReady));
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'This capture could not be saved.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _addSelected() async {
    final review = _review;
    if (_working || review == null || _selected.isEmpty) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final error = await widget.onApply(
        review,
        review.proposals.where(_selected.contains).toList(),
      );
      if (!mounted) return;
      if (error == null) {
        Navigator.pop(context);
      } else {
        setState(() => _error = error);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The selected items could not be saved.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _clearReview() {
    setState(() {
      _review = null;
      _error = null;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final review = _review;
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final drafts = widget.drafts.reversed.where((entry) => !entry.applied);
    return PopScope(
      canPop: !_working,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: mobile ? MediaQuery.viewInsetsOf(context).bottom : 0,
        ),
        child: SafeArea(
          top: false,
          bottom: mobile,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Capture review',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close capture review',
                        onPressed: _working
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _controller,
                    enabled: !_working,
                    minLines: 2,
                    maxLines: 6,
                    maxLength: 12000,
                    onChanged: (_) => _clearReview(),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Capture text',
                      hintText: 'Add a task, event, or note',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  if (review == null &&
                      _controller.text.isEmpty &&
                      drafts.isNotEmpty)
                    ExpansionTile(
                      title: const Text('Saved drafts'),
                      tilePadding: EdgeInsets.zero,
                      children: [
                        for (final draft in drafts.take(10))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              draft.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: !_working
                                ? () => setState(() {
                                    _draftId = draft.id;
                                    _controller.text = draft.text;
                                    _error = null;
                                  })
                                : null,
                          ),
                      ],
                    ),
                  if (review != null) ...[
                    const SizedBox(height: 14),
                    for (final proposal in review.proposals)
                      _ProposalTile(
                        proposal: proposal,
                        anchor: review.input.context.anchor,
                        selected: _selected.contains(proposal),
                        toggle: _working || !proposal.isReady
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _selected.add(proposal);
                                } else {
                                  _selected.remove(proposal);
                                }
                              }),
                      ),
                    for (final issue in review.issues)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(
                          issue.message,
                          style: const TextStyle(color: muted),
                        ),
                      ),
                  ],
                  if (_error case final error?) ...[
                    const SizedBox(height: 9),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton(
                      onPressed: _working
                          ? null
                          : review == null
                          ? _reviewText
                          : _selected.isEmpty
                          ? null
                          : _addSelected,
                      child: Text(
                        _working
                            ? 'Saving…'
                            : review == null
                            ? 'Review'
                            : _selected.length == 1
                            ? 'Add 1 item'
                            : 'Add ${_selected.length} items',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProposalTile extends StatelessWidget {
  const _ProposalTile({
    required this.proposal,
    required this.anchor,
    required this.selected,
    required this.toggle,
  });

  final CaptureProposal proposal;
  final DateTime anchor;
  final bool selected;
  final ValueChanged<bool?>? toggle;

  @override
  Widget build(BuildContext context) {
    final draft = proposal.draft;
    final localizations = MaterialLocalizations.of(context);
    String date(DateTime value) => localizations.formatMediumDate(value);
    String time(DateTime value) => localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final label = switch (draft.kind) {
      CaptureIntentKind.task => 'Task',
      CaptureIntentKind.event => 'Event',
      CaptureIntentKind.note => 'Note',
      CaptureIntentKind.workout => 'Workout note',
      CaptureIntentKind.meal => 'Meal note',
      CaptureIntentKind.completeTask => 'Complete task',
    };
    final category =
        draft.category ??
        switch (draft.kind) {
          CaptureIntentKind.task || CaptureIntentKind.event => 'personal',
          CaptureIntentKind.workout => 'gym',
          CaptureIntentKind.meal => 'health',
          _ => null,
        };
    final detail = switch (draft) {
      CaptureTaskDraft(:final dueDate) =>
        dueDate == null
            ? 'Due ${date(anchor)} (default)'
            : 'Due ${date(dueDate)}',
      CaptureEventDraft(:final start?, :final end?, :final allDay) =>
        allDay
            ? '${date(start)} · All day'
            : '${date(start)} · ${time(start)}–${time(end)}',
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: selected,
          onChanged: toggle,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(draft.title),
          subtitle: Text(
            [
              label,
              if (category != null) spaceName(category),
              ?detail,
              if (proposal.missingRequired.isNotEmpty)
                'Needs ${proposal.missingRequired.join(', ')}',
              for (final issue in proposal.issues) issue.message,
            ].join(' · '),
          ),
        ),
        const Divider(),
      ],
    );
  }
}
