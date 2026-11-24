import 'package:material_ui/material_ui.dart';

import 'task_breakdown.dart';

Future<TaskBreakdownApproval?> showTaskBreakdownReview(
  BuildContext context, {
  required TaskBreakdownReview review,
}) => showDialog<TaskBreakdownApproval>(
  context: context,
  builder: (_) => _BreakdownReview(review: review),
);

class _BreakdownReview extends StatefulWidget {
  const _BreakdownReview({required this.review});

  final TaskBreakdownReview review;

  @override
  State<_BreakdownReview> createState() => _BreakdownReviewState();
}

class _BreakdownReviewState extends State<_BreakdownReview> {
  late final _fields = [
    for (final proposal in widget.review.proposals)
      TextEditingController(text: proposal.title),
  ];
  final _selected = <int>{};
  String? _error;

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  void _apply() {
    final approval = widget.review.approve({
      for (final index in _selected) index: _fields[index].text,
    });
    if (approval == null) {
      setState(() => _error = 'Use a distinct title for each selected step.');
      return;
    }
    Navigator.pop(context, approval);
  }

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      scrollable: true,
      title: const Text('Break down task'),
      content: SizedBox(
        width: 390,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              review.parentTitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if (review.proposals.isEmpty)
              const Text('No distinct steps found in this title.'),
            for (final (index, proposal) in review.proposals.indexed)
              Row(
                children: [
                  Checkbox(
                    semanticLabel: 'Include ${proposal.title}',
                    value: _selected.contains(index),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected.add(index);
                      } else {
                        _selected.remove(index);
                      }
                      _error = null;
                    }),
                  ),
                  Expanded(
                    child: Semantics(
                      label: 'Subtask title',
                      child: TextField(
                        key: ValueKey('breakdown-title-$index'),
                        controller: _fields[index],
                        textCapitalization: TextCapitalization.sentences,
                        minLines: 1,
                        maxLines: 3,
                        maxLength: maxBreakdownTitleLength,
                        decoration: const InputDecoration(
                          isDense: true,
                          counterText: '',
                        ),
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            if (_error case final error?)
              Semantics(
                liveRegion: true,
                child: Text(error, style: TextStyle(color: colors.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(review.proposals.isEmpty ? 'Close' : 'Cancel'),
        ),
        if (review.proposals.isNotEmpty)
          FilledButton(
            onPressed: _selected.isEmpty ? null : _apply,
            child: const Text('Add selected'),
          ),
      ],
    );
  }
}
