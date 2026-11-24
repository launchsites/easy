import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'ai_runtime.dart';

class TaskEstimateReviewItem {
  const TaskEstimateReviewItem({
    required this.estimate,
    required this.title,
    this.issue,
  });

  final AiPendingEstimate estimate;
  final String title;
  final String? issue;
}

class TaskEstimatesPage extends StatefulWidget {
  const TaskEstimatesPage({
    required this.runtime,
    required this.readItems,
    required this.onAccept,
    super.key,
  });

  final AiRuntime runtime;
  final Iterable<TaskEstimateReviewItem> Function() readItems;
  final Future<void> Function(AiPendingEstimate) onAccept;

  @override
  State<TaskEstimatesPage> createState() => _TaskEstimatesPageState();
}

class _TaskEstimatesPageState extends State<TaskEstimatesPage> {
  bool _busy = false;
  String? _feedback;

  Future<void> _review(
    AiPendingEstimate estimate, {
    required bool accept,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      if (accept) {
        await widget.onAccept(estimate);
      } else if (!await widget.runtime.discardPendingEstimate(estimate)) {
        throw StateError('The estimate changed.');
      }
      if (mounted) {
        setState(
          () => _feedback = accept ? 'Estimate saved.' : 'Estimate dismissed.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _feedback =
              'This estimate could not be saved. Check the current task.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        final items = widget.readItems();
        final localizations = MaterialLocalizations.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('Duration suggestions')),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 660),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 28),
                  children: [
                    if (_feedback case final text?)
                      Semantics(
                        liveRegion: true,
                        child: Text(text, style: contentMetadataStyle),
                      ),
                    if (items.isEmpty)
                      const Text(
                        'No suggestions to review.',
                        style: contentMetadataStyle,
                      ),
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Card(
                          color: raisedPaper,
                          elevation: 0,
                          shape: const RoundedRectangleBorder(
                            borderRadius: contentSurfaceRadius,
                            side: BorderSide(color: line),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(15, 14, 15, 9),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              spacing: 7,
                              children: [
                                Text(item.title, style: contentTitleStyle),
                                Text(
                                  '${item.estimate.durationMinutes} min · ${item.estimate.route == AiRoute.local ? 'Local model' : 'Configured API'}',
                                  style: sectionHeadingStyle,
                                ),
                                Text(
                                  localizations.formatMediumDate(
                                    item.estimate.createdAt.toLocal(),
                                  ),
                                  style: contentMetadataStyle,
                                ),
                                if (item.issue case final issue?)
                                  Text(issue, style: contentMetadataStyle),
                                Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _review(
                                                item.estimate,
                                                accept: false,
                                              ),
                                        child: const Text('Dismiss'),
                                      ),
                                      FilledButton.tonal(
                                        onPressed: _busy || item.issue != null
                                            ? null
                                            : () => _review(
                                                item.estimate,
                                                accept: true,
                                              ),
                                        child: const Text('Use estimate'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
