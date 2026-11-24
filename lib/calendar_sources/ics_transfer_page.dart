import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart' as palette;
import 'ics_calendar.dart';
import 'ics_import_export.dart';
import 'ics_occurrence_expander.dart';

class IcsTransferSelection {
  IcsTransferSelection._({
    required this.importId,
    required this.originalCalendar,
    required this.calendar,
    required Iterable<int> selectedSourceIndexes,
    required Iterable<IcsImportOccurrence> previewItems,
  }) : selectedSourceIndexes = Set.unmodifiable(selectedSourceIndexes),
       previewItems = List.unmodifiable(previewItems);

  final String importId;
  final IcsCalendar originalCalendar;
  final IcsCalendar calendar;
  final Set<int> selectedSourceIndexes;

  /// Items use the selected document's ordering when computing local IDs.
  final List<IcsImportOccurrence> previewItems;
}

class IcsTransferPage extends StatefulWidget {
  const IcsTransferPage({
    required this.pickFile,
    required this.onApply,
    required this.saveFile,
    this.exportCalendar,
    this.initialDate,
    this.floatingTimeZone,
    this.exportName = 'Easy Calendar.ics',
    super.key,
  });

  final Future<String?> Function() pickFile;

  /// Saves the selected source document as a local calendar. A retry receives
  /// the same import ID.
  final Future<void> Function(IcsTransferSelection selection) onApply;
  final Future<bool> Function(String suggestedName, String contents) saveFile;
  final IcsCalendar? exportCalendar;
  final DateTime? initialDate;
  final String? floatingTimeZone;
  final String exportName;

  @override
  State<IcsTransferPage> createState() => _IcsTransferPageState();
}

class _IcsTransferPageState extends State<IcsTransferPage> {
  static const _contentWidth = 660.0;

  late DateTimeRange<DateTime> _dates;
  IcsCalendar? _document;
  IcsImportPreview? _preview;
  String? _importId;
  List<_ImportChoice> _choices = const [];
  final _selected = <int>{};
  bool _working = false;
  String? _problem;
  String? _notice;

  @override
  void initState() {
    super.initState();
    final start = DateUtils.dateOnly(widget.initialDate ?? DateTime.now());
    _dates = DateTimeRange(
      start: start,
      end: DateUtils.addDaysToDate(start, 29),
    );
  }

  Future<void> _pick() async {
    _begin();
    try {
      final contents = await widget.pickFile();
      if (!mounted || contents == null) return;
      setState(() {
        _document = null;
        _preview = null;
        _importId = _newImportId();
        _choices = const [];
        _selected.clear();
      });
      final document = await compute(IcsCalendar.parse, contents);
      if (!mounted) return;
      final choices = _importChoices(document);
      setState(() {
        _document = document;
        _choices = choices;
        _selected.addAll(choices.map((choice) => choice.representative));
      });
      await _loadPreview();
    } on FormatException catch (error) {
      if (mounted) setState(() => _problem = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'The calendar file could not be opened.');
      }
    } finally {
      _end();
    }
  }

  Future<void> _changeDates() async {
    final year = _dates.start.year;
    final selected = await showDateRangePicker(
      context: context,
      initialDateRange: _dates,
      firstDate: DateTime(year - 100),
      lastDate: DateTime(year + 100, 12, 31),
      helpText: 'Preview dates',
      saveText: 'Preview',
    );
    if (!mounted || selected == null) return;
    setState(() {
      _dates = selected;
      _preview = null;
      _problem = null;
      _notice = null;
    });
    if (_document == null) return;
    _begin();
    try {
      await _loadPreview();
    } finally {
      _end();
    }
  }

  Future<void> _loadPreview() async {
    try {
      final preview = await _buildPreview(_document!);
      if (mounted) setState(() => _preview = preview);
    } on IcsExpansionException catch (error) {
      if (mounted) setState(() => _problem = error.message);
    } on ArgumentError {
      if (mounted) {
        setState(() => _problem = 'Choose preview dates within one year.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _problem = 'The calendar preview could not be prepared.',
        );
      }
    }
  }

  Future<IcsImportPreview> _buildPreview(IcsCalendar calendar) =>
      compute(_previewTransfer, (
        calendar: calendar,
        importId: _importId!,
        start: _dates.start,
        end: DateUtils.addDaysToDate(_dates.end, 1),
        floatingTimeZone: widget.floatingTimeZone,
      ));

  Future<void> _apply() async {
    final document = _document!;
    final indices = {
      for (final choice in _choices)
        if (_selected.contains(choice.representative)) ...choice.sourceIndexes,
    };
    final calendar = document.withEvents([
      for (final (index, event) in document.events.indexed)
        if (indices.contains(index)) event,
    ]);
    _begin();
    try {
      final selectedPreview = await _buildPreview(calendar);
      if (!mounted) return;
      await widget.onApply(
        IcsTransferSelection._(
          importId: _importId!,
          originalCalendar: document,
          calendar: calendar,
          selectedSourceIndexes: indices,
          previewItems: selectedPreview.items,
        ),
      );
      if (!mounted) return;
      setState(() {
        _document = null;
        _preview = null;
        _importId = null;
        _choices = const [];
        _selected.clear();
        _notice = 'Calendar imported.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _problem = 'The selected calendar items could not be imported.',
        );
      }
    } finally {
      _end();
    }
  }

  Future<void> _export() async {
    final calendar = widget.exportCalendar;
    if (calendar == null) return;
    _begin();
    try {
      final contents = await compute(_encodeCalendar, calendar);
      if (!mounted) return;
      final saved = await widget.saveFile(widget.exportName, contents);
      if (mounted && saved) setState(() => _notice = 'Calendar exported.');
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'The calendar could not be exported.');
      }
    } finally {
      _end();
    }
  }

  void _begin() => setState(() {
    _working = true;
    _notice = null;
    _problem = null;
  });

  void _end() {
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = _preview;
    final occurrencesBySource = <int, List<IcsOccurrence>>{};
    for (final item in preview?.items ?? const <IcsImportOccurrence>[]) {
      occurrencesBySource
          .putIfAbsent(item.occurrence.sourceIndex, () => [])
          .add(item.occurrence);
    }
    final canApply = !_working && preview != null && _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar transfer')),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentWidth),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
              itemCount: 1 + (preview == null ? 0 : _choices.length),
              itemBuilder: (context, index) {
                if (index > 0) {
                  return _choiceRow(
                    context,
                    _choices[index - 1],
                    occurrencesBySource,
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        FilledButton(
                          onPressed: _working ? null : _pick,
                          child: const Text('Choose .ics file'),
                        ),
                        if (widget.exportCalendar != null)
                          OutlinedButton(
                            onPressed: _working ? null : _export,
                            child: const Text('Export calendar'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Preview dates'),
                      subtitle: Text(
                        '${localizations.formatMediumDate(_dates.start)} – ${localizations.formatMediumDate(_dates.end)}',
                      ),
                      trailing: const Icon(Icons.edit_calendar_outlined),
                      onTap: _working ? null : _changeDates,
                    ),
                    if (_working) const LinearProgressIndicator(),
                    if (_problem case final problem?)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            problem,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                    if (_notice case final notice?)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Semantics(liveRegion: true, child: Text(notice)),
                      ),
                    if (preview != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        preview.calendar.name ?? 'Calendar preview',
                        style: palette.sectionHeadingStyle,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _choices.isEmpty ? 'No events available to import.' : 'Choose events to add to Easy. A recurring series includes its full schedule.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                heightFactor: 1,
                child: FilledButton(
                  onPressed: canApply ? _apply : null,
                  child: const Text('Import selected'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choiceRow(
    BuildContext context,
    _ImportChoice choice,
    Map<int, List<IcsOccurrence>> occurrencesBySource,
  ) {
    final localizations = MaterialLocalizations.of(context);
    final occurrences = [
      for (final source in choice.sourceIndexes)
        ...occurrencesBySource[source] ?? const <IcsOccurrence>[],
    ]..sort((first, second) => first.start.compareTo(second.start));
    final first = occurrences.firstOrNull;
    final details = [
      if (first != null)
        localizations.formatMediumDate(
          first.allDay ? first.start : first.start.toLocal(),
        ),
      if (first != null && !first.allDay)
        localizations.formatTimeOfDay(
          TimeOfDay.fromDateTime(first.start.toLocal()),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        ),
      if (occurrences.isEmpty) 'Outside preview dates',
      if (occurrences.length > 1) '${occurrences.length} occurrences',
      if (choice.recurring) 'Series',
      if (choice.duplicate) 'Duplicate source UID',
    ];
    return CheckboxListTile(
      key: ValueKey(choice.representative),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        choice.event.summary.isEmpty ? 'Untitled event' : choice.event.summary,
      ),
      subtitle: Text(details.join(' · ')),
      value: _selected.contains(choice.representative),
      onChanged: _working
          ? null
          : (checked) => setState(() {
              if (checked == true) {
                _selected.add(choice.representative);
              } else {
                _selected.remove(choice.representative);
              }
            }),
    );
  }
}

typedef _PreviewRequest = ({
  IcsCalendar calendar,
  String importId,
  DateTime start,
  DateTime end,
  String? floatingTimeZone,
});

IcsImportPreview _previewTransfer(_PreviewRequest request) {
  if (request.calendar.method?.toUpperCase() == 'CANCEL') {
    throw const IcsExpansionException(
      'This file contains cancellation notices. Choose an exported calendar file.',
    );
  }
  return previewIcsImport(
    request.calendar,
    importId: request.importId,
    windowStart: request.start,
    windowEnd: request.end,
    floatingTimeZone: request.floatingTimeZone,
    limit: 1000,
  );
}

String _encodeCalendar(IcsCalendar calendar) => calendar.encode();

int _importSequence = 0;

String _newImportId() =>
    'ics-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${(_importSequence++).toRadixString(36)}';

class _ImportChoice {
  const _ImportChoice(
    this.representative,
    this.event,
    this.sourceIndexes,
    this.duplicate,
  );

  final int representative;
  final IcsEvent event;
  final List<int> sourceIndexes;
  final bool duplicate;

  bool get recurring =>
      sourceIndexes.length > 1 ||
      event.recurrenceRule != null ||
      event.recurrenceDates.isNotEmpty ||
      event.recurrenceId != null ||
      event.recurrencePeriods.isNotEmpty;
}

List<_ImportChoice> _importChoices(IcsCalendar calendar) {
  final masters = {
    for (final (index, event) in calendar.events.indexed)
      if (event.recurrenceId == null) event.uid: index,
  };
  final groups = <int, List<int>>{};
  for (final (index, event) in calendar.events.indexed) {
    final representative = event.recurrenceId == null
        ? index
        : masters[event.uid] ?? index;
    if (calendar.events[representative].status?.toUpperCase() == 'CANCELLED') {
      continue;
    }
    groups.putIfAbsent(representative, () => []).add(index);
  }
  final counts = <String, int>{};
  for (final index in groups.keys) {
    counts.update(
      calendar.events[index].uid,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  return [
    for (final index in groups.keys.toList()..sort())
      _ImportChoice(
        index,
        calendar.events[index],
        groups[index]!,
        counts[calendar.events[index].uid]! > 1,
      ),
  ];
}
