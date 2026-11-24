import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'future_block_removal.dart';

Future<FutureBlockRemovalSelection?> showFutureBlockRemovalReview(
  BuildContext context, {
  required FutureBlockRemovalReview review,
}) => showDialog<FutureBlockRemovalSelection>(
  context: context,
  builder: (context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width < 480 ? 12 : 40,
        vertical: size.height < 450 ? 8 : 24,
      ),
      child: _FutureBlockRemovalSheet(review: review),
    );
  },
);

class _FutureBlockRemovalSheet extends StatefulWidget {
  const _FutureBlockRemovalSheet({required this.review});

  final FutureBlockRemovalReview review;

  @override
  State<_FutureBlockRemovalSheet> createState() =>
      _FutureBlockRemovalSheetState();
}

class _FutureBlockRemovalSheetState extends State<_FutureBlockRemovalSheet> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final colors = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final media = MediaQuery.of(context);
    final short = media.size.height < 450;
    final allSelected =
        review.blocks.isNotEmpty && _selected.length == review.blocks.length;
    String time(DateTime date) => localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
      alwaysUse24HourFormat: media.alwaysUse24HourFormat,
    );

    final height = media.size.height * (short ? .93 : .78);
    final preferredHeight = 195 + review.blocks.length.clamp(0, 5) * 65;
    return SizedBox(
      width: 464,
      height: height < preferredHeight ? height : preferredHeight.toDouble(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(18, 15, 8, 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 5,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  'Future blocks',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: sectionHeadingStyle.copyWith(
                                    color: colors.onSurface,
                                  ),
                                ),
                              ),
                              Text(
                                review.taskTitle,
                                maxLines: short ? 1 : 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close review',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
                if (review.blocks.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(18, 8, 18, 18),
                      child: Text('There are no future blocks to remove.'),
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 7),
                        child: TextButton(
                          onPressed: () => setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected.addAll(
                                review.blocks.map((event) => event.id),
                              );
                            }
                          }),
                          child: Text(
                            allSelected ? 'Clear selection' : 'Select all',
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsetsDirectional.fromSTEB(6, 0, 6, 4),
                    sliver: SliverList.builder(
                      itemCount: review.blocks.length,
                      itemBuilder: (context, index) {
                        final block = review.blocks[index];
                        final start = block.start.toLocal();
                        final end = block.end.toLocal();
                        final date = localizations.formatMediumDate(start);
                        final times = '${time(start)}–${time(end)}';
                        final spansDays = !DateUtils.isSameDay(start, end);
                        return CheckboxListTile(
                          key: ValueKey(block.id),
                          value: _selected.contains(block.id),
                          title: Text(
                            block.title == review.taskTitle
                                ? date
                                : block.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (block.title != review.taskTitle) date,
                              if (spansDays)
                                '$times · ${localizations.formatMediumDate(end)}'
                              else
                                times,
                            ].join(' · '),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              _selected.add(block.id);
                            } else {
                              _selected.remove(block.id);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (review.blocks.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 14, 14),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  ),
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.pop(context, review.select(_selected)),
                  child: Text(switch (_selected.length) {
                    0 => 'Remove selected',
                    1 => 'Remove one block',
                    final count => 'Remove $count blocks',
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
