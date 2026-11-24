import 'package:material_ui/material_ui.dart';

import '../categories/category_palette.dart';
import '../gym_session.dart';
import '../ui_theme.dart';
import 'capture_archive.dart';
import 'capture_interpreter.dart';
import 'task_category_hint.dart';

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
  Map<CaptureProposal, CaptureWorkoutSelection>,
);
typedef CaptureWorkoutPreview = ({
  GymWorkoutCaptureDraft? draft,
  String detail,
});
typedef CaptureWorkoutSelection = ({
  GymWorkoutCaptureDraft draft,
  bool markExplicitCompletion,
});
typedef ReviewCaptureWithAi =
    Future<
      ({CaptureArchiveEntry? draft, CaptureReview? review, String? message})
    >
    Function(BuildContext context, {String? draftId, required String text});

class CaptureReviewSheet extends StatefulWidget {
  const CaptureReviewSheet({
    required this.initialText,
    required this.drafts,
    required this.onReview,
    required this.onApply,
    this.initialDraft,
    this.onPlayDraft,
    this.onAiReview,
    this.onCancelAi,
    this.onTranscribe,
    this.onCancelTranscription,
    this.defaultTaskDate,
    this.defaultCategory,
    this.onInspectWorkout,
    this.disabledKinds = const {},
    super.key,
  });

  final String initialText;
  final List<CaptureArchiveEntry> drafts;
  final ReviewCaptureText onReview;
  final ApplyCaptureItems onApply;
  final CaptureArchiveEntry? initialDraft;
  final Future<void> Function(CaptureArchiveEntry)? onPlayDraft;
  final ReviewCaptureWithAi? onAiReview;
  final VoidCallback? onCancelAi;
  final Future<CaptureArchiveEntry> Function(CaptureArchiveEntry)? onTranscribe;
  final VoidCallback? onCancelTranscription;
  final DateTime? Function(DateTime)? defaultTaskDate;
  final String? Function(CaptureProposal)? defaultCategory;
  final CaptureWorkoutPreview? Function(CaptureReview, CaptureProposal)?
  onInspectWorkout;
  final Set<CaptureIntentKind> disabledKinds;

  @override
  State<CaptureReviewSheet> createState() => _CaptureReviewSheetState();
}

class _CaptureReviewSheetState extends State<CaptureReviewSheet> {
  late final _controller = TextEditingController(text: widget.initialText);
  CaptureReview? _review;
  CaptureArchiveEntry? _selectedDraft;
  int _draftLimit = 10;
  String? _error;
  var _working = false;
  var _usingAi = false;
  var _transcribing = false;
  final _selected = <CaptureProposal>{};
  var _workouts = <CaptureProposal, CaptureWorkoutPreview>{};
  final _completedWorkouts = <CaptureProposal>{};

  @override
  void initState() {
    super.initState();
    _selectedDraft = widget.initialDraft;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reviewText({bool useAi = false}) async {
    final text = _controller.text.trim();
    if (_working || text.isEmpty) return;
    setState(() {
      _working = true;
      _usingAi = useAi;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      final id = _selectedDraft?.id;
      final result = useAi && widget.onAiReview != null
          ? await widget.onAiReview!(context, draftId: id, text: text)
          : (
              draft: null,
              review: await widget.onReview(draftId: id, text: text),
              message: null,
            );
      if (!mounted) return;
      final review = result.review;
      if (review == null) {
        setState(() {
          _selectedDraft = result.draft ?? _selectedDraft;
          _error = result.message;
        });
        return;
      }
      setState(() {
        _error = result.message;
        final old = _selectedDraft;
        _selectedDraft =
            result.draft ??
            CaptureArchiveEntry(
              id: review.input.id,
              text: text,
              capturedAt: old?.capturedAt ?? review.input.context.anchor,
              revision: review.input.revision,
              audio: old?.audio,
            );
        _review = review;
        _workouts = {
          if (widget.onInspectWorkout case final inspect?)
            for (final proposal in review.proposals)
              if (proposal.isReady &&
                  !widget.disabledKinds.contains(proposal.draft.kind))
                proposal: ?inspect(review, proposal),
        };
        _completedWorkouts.clear();
        _selected
          ..clear()
          ..addAll(
            review.proposals.where(
              (proposal) =>
                  proposal.isReady &&
                  !proposal.requiresSelection &&
                  !widget.disabledKinds.contains(proposal.draft.kind),
            ),
          );
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'This capture could not be saved.');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _usingAi = false;
        });
      }
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
      final selected = review.proposals.where(_selected.contains).toList();
      final error = await widget.onApply(review, selected, {
        for (final proposal in selected)
          if (_workouts[proposal]?.draft case final draft?)
            proposal: (
              draft: draft,
              markExplicitCompletion: _completedWorkouts.contains(proposal),
            ),
      });
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
      _workouts.clear();
      _completedWorkouts.clear();
    });
  }

  Future<void> _transcribe() async {
    final draft = _selectedDraft;
    if (_working || draft?.audio == null || widget.onTranscribe == null) return;
    // The transcript is separate from any text already entered by the user.
    if (_controller.text.trim().isNotEmpty) return;
    setState(() {
      _working = true;
      _transcribing = true;
      _error = null;
    });
    try {
      final transcript = await widget.onTranscribe!(draft!);
      if (!mounted) return;
      setState(() {
        _selectedDraft = transcript;
        _controller.text = transcript.text;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'The recording is saved. Transcription did not finish.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _transcribing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = _review;
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final drafts = widget.drafts.reversed.where((entry) => !entry.applied);
    final selectedDraft = _selectedDraft;
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
                  if (selectedDraft?.audio != null &&
                      widget.onPlayDraft != null)
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: _working
                              ? null
                              : () => widget.onPlayDraft!(selectedDraft!),
                          icon: const Icon(
                            Icons.play_circle_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('Play recording'),
                        ),
                        if (_transcribing)
                          TextButton(
                            onPressed: widget.onCancelTranscription,
                            child: const Text('Stop transcription'),
                          )
                        else if (widget.onTranscribe != null &&
                            _controller.text.trim().isEmpty)
                          TextButton(
                            onPressed: _working ? null : _transcribe,
                            child: const Text('Transcribe locally'),
                          ),
                      ],
                    ),
                  TextField(
                    controller: _controller,
                    enabled: !_working,
                    minLines: 2,
                    maxLines: 6,
                    maxLength: 12000,
                    onChanged: (_) => _clearReview(),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: selectedDraft?.audio == null
                          ? 'Capture text'
                          : 'Transcript',
                      hintText: selectedDraft?.audio == null
                          ? 'Add a task, event, or note'
                          : 'Type what you said',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  if (review == null &&
                      _controller.text.isEmpty &&
                      selectedDraft == null &&
                      drafts.isNotEmpty)
                    ExpansionTile(
                      title: const Text('Saved drafts'),
                      tilePadding: EdgeInsets.zero,
                      children: [
                        for (final draft in drafts.take(_draftLimit))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              draft.text.isEmpty ? 'Voice capture' : draft.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: !_working
                                ? () => setState(() {
                                    _selectedDraft = draft;
                                    _controller.text = draft.text;
                                    _error = null;
                                  })
                                : null,
                          ),
                        if (drafts.skip(_draftLimit).isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() => _draftLimit += 10),
                            child: const Text('Show more drafts'),
                          ),
                      ],
                    ),
                  if (review != null) ...[
                    const SizedBox(height: 14),
                    for (final proposal in review.proposals)
                      _ProposalTile(
                        proposal: proposal,
                        anchor: review.input.context.anchor,
                        defaultTaskDate: widget.defaultTaskDate,
                        defaultCategory: widget.defaultCategory,
                        featureDisabled: widget.disabledKinds.contains(
                          proposal.draft.kind,
                        ),
                        workout: _workouts[proposal],
                        workoutComplete: _completedWorkouts.contains(proposal),
                        toggleWorkoutComplete:
                            _working || !_selected.contains(proposal)
                            ? null
                            : (checked) => setState(() {
                                if (checked == true) {
                                  _completedWorkouts.add(proposal);
                                } else {
                                  _completedWorkouts.remove(proposal);
                                }
                              }),
                        selected: _selected.contains(proposal),
                        toggle:
                            _working ||
                                !proposal.isReady ||
                                widget.disabledKinds.contains(
                                  proposal.draft.kind,
                                )
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _selected.add(proposal);
                                } else {
                                  _selected.remove(proposal);
                                  _completedWorkouts.remove(proposal);
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
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_usingAi && widget.onCancelAi != null)
                          TextButton(
                            onPressed: widget.onCancelAi,
                            child: const Text('Cancel AI'),
                          )
                        else if (!_working &&
                            widget.onAiReview != null &&
                            _controller.text.trim().isNotEmpty)
                          OutlinedButton(
                            onPressed: () => _reviewText(useAi: true),
                            child: const Text('Review with AI'),
                          ),
                        FilledButton(
                          onPressed: _working
                              ? null
                              : review == null
                              ? _reviewText
                              : _selected.isEmpty
                              ? null
                              : _addSelected,
                          child: Text(
                            _usingAi
                                ? 'Reviewing…'
                                : _transcribing
                                ? 'Transcribing…'
                                : _working
                                ? 'Saving…'
                                : review == null
                                ? 'Review'
                                : _selected.length == 1
                                ? 'Add 1 item'
                                : 'Add ${_selected.length} items',
                          ),
                        ),
                      ],
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
    required this.featureDisabled,
    required this.defaultTaskDate,
    required this.defaultCategory,
    required this.workout,
    required this.workoutComplete,
    required this.toggleWorkoutComplete,
  });

  final CaptureProposal proposal;
  final DateTime anchor;
  final bool selected;
  final ValueChanged<bool?>? toggle;
  final bool featureDisabled;
  final DateTime? Function(DateTime)? defaultTaskDate;
  final String? Function(CaptureProposal)? defaultCategory;
  final CaptureWorkoutPreview? workout;
  final bool workoutComplete;
  final ValueChanged<bool?>? toggleWorkoutComplete;

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
      CaptureIntentKind.workout => 'Workout entry',
      CaptureIntentKind.meal => 'Meal draft',
      CaptureIntentKind.completeTask => 'Complete task',
    };
    final category =
        draft.category ??
        (defaultCategory != null
            ? defaultCategory!(proposal)
            : switch (draft.kind) {
                CaptureIntentKind.task || CaptureIntentKind.event => 'personal',
                CaptureIntentKind.workout => 'gym',
                CaptureIntentKind.meal => 'health',
                _ => null,
              });
    final preferred = defaultTaskDate == null
        ? anchor
        : defaultTaskDate!(anchor);
    final detail = switch (draft) {
      CaptureTaskDraft(:final dueDate) =>
        dueDate == null
            ? (preferred == null ? 'Inbox' : '${date(preferred)} (default)')
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
          title: Text(workout?.draft?.title ?? draft.title),
          subtitle: Text(
            [
              label,
              if (category != null)
                WorkspaceCategoryPalette.labelFor(context, category),
              if (featureDisabled) 'Feature turned off',
              if (proposal.requiresSelection) 'AI suggestion',
              if (draft is CaptureTaskDraft)
                ?taskSchedulingHoldHint(draft.title)?.message,
              ?detail,
              ?workout?.detail,
              if (proposal.missingRequired.isNotEmpty)
                'Needs ${proposal.missingRequired.join(', ')}',
              for (final issue in proposal.issues) issue.message,
            ].join(' · '),
          ),
        ),
        if (selected && workout?.draft?.canConfirmCompletion == true)
          CheckboxListTile(
            dense: true,
            value: workoutComplete,
            onChanged: toggleWorkoutComplete,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              workout?.draft?.kind == GymWorkoutCaptureKind.strength
                  ? 'Mark these sets done'
                  : 'Mark this exercise done',
            ),
          ),
        const Divider(),
      ],
    );
  }
}
