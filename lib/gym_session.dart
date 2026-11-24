import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart';

@immutable
class GymLogEntry {
  const GymLogEntry({
    required this.id,
    required this.title,
    required this.loggedAt,
    this.actual,
    this.exerciseId,
  });

  final String id;
  final String title;
  final DateTime loggedAt;
  final String? actual;
  final String? exerciseId;

  GymLogEntry._fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      title = json['title'] as String,
      loggedAt = DateTime.parse(json['loggedAt'] as String),
      actual = json['actual'] as String?,
      exerciseId = json['exerciseId'] as String?;

  Map<String, Object?> _toJson() => {
    'id': id,
    'title': title,
    'loggedAt': loggedAt.toIso8601String(),
    'actual': actual,
    'exerciseId': exerciseId,
  };
}

@immutable
class GymSession {
  GymSession._({
    required this.planned,
    required this.startedAt,
    this.finishedAt,
    Iterable<GymLogEntry> entries = const [],
  }) : entries = List.unmodifiable(entries);

  final bool planned;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final List<GymLogEntry> entries;

  bool get finished => finishedAt != null;

  factory GymSession.decode(String source) =>
      GymSession._fromJson(jsonDecode(source) as Map<String, dynamic>);

  GymSession._fromJson(Map<String, dynamic> json)
    : this._(
        planned: json['planned'] as bool,
        startedAt: DateTime.parse(json['startedAt'] as String),
        finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
        entries: (json['entries'] as List<dynamic>).map(
          (entry) => GymLogEntry._fromJson(entry as Map<String, dynamic>),
        ),
      );

  String encode() => jsonEncode(_toJson());

  Map<String, Object?> _toJson() => {
    'planned': planned,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'entries': entries.map((entry) => entry._toJson()).toList(),
  };

  GymSession _withEntries(List<GymLogEntry> entries) => GymSession._(
    planned: planned,
    startedAt: startedAt,
    finishedAt: finishedAt,
    entries: entries,
  );

  GymSession _finish(DateTime date) => GymSession._(
    planned: planned,
    startedAt: startedAt,
    finishedAt: date,
    entries: entries,
  );
}

class GymSessionPage extends StatefulWidget {
  const GymSessionPage({
    required this.session,
    required this.onChanged,
    super.key,
  });

  final GymSession? session;
  final ValueChanged<GymSession?> onChanged;

  @override
  State<GymSessionPage> createState() => _GymSessionPageState();
}

typedef _Exercise = ({String id, String title, String target});

const _exercises = <_Exercise>[
  (id: 'treadmill', title: 'Treadmill', target: '0.5 km · 5 min · 2% incline'),
  (id: 'bench', title: 'Bench press', target: '50 kg × 8, 8, 8'),
];

class _GymSessionPageState extends State<GymSessionPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  late GymSession? _session = widget.session;
  GymLogEntry? _editingEntry;
  _Exercise? _editingExercise;
  String _extraDraft = '';
  String? _error;

  bool get _editing => _editingEntry != null || _editingExercise != null;
  bool get _active => _session != null && !_session!.finished;

  @override
  void didUpdateWidget(covariant GymSessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session != oldWidget.session) _session = widget.session;
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _update(GymSession session) {
    setState(() => _session = session);
    widget.onChanged(session);
  }

  void _begin(bool planned) {
    _update(GymSession._(planned: planned, startedAt: DateTime.now()));
  }

  Future<void> _finish() async {
    final session = _session!;
    final initialEdit =
        _editingEntry?.actual ??
        _editingEntry?.title ??
        _editingExercise?.target;
    final pending = _input.text.trim();
    if (_extraDraft.isNotEmpty ||
        (pending.isNotEmpty && pending != initialEdit)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard draft and finish?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep logging'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Finish'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    _focus.unfocus();
    _cancelEdit();
    _input.clear();
    _update(session._finish(DateTime.now()));
  }

  void _logExercise(_Exercise exercise, String actual) {
    final existing = _session!.entries
        .where((entry) => entry.exerciseId == exercise.id)
        .firstOrNull;
    if (existing != null) {
      if (existing.actual != actual) _replaceEntry(existing, actual);
      return;
    }
    _append(title: exercise.title, actual: actual, exerciseId: exercise.id);
  }

  void _append({required String title, String? actual, String? exerciseId}) {
    final session = _session!;
    final now = DateTime.now();
    final entry = GymLogEntry(
      id: '${now.microsecondsSinceEpoch}-${session.entries.length}',
      title: title,
      loggedAt: now,
      actual: actual,
      exerciseId: exerciseId,
    );
    _update(session._withEntries([...session.entries, entry]));
  }

  void _edit({GymLogEntry? entry, _Exercise? exercise}) {
    final value = entry?.actual ?? entry?.title ?? exercise!.target;
    setState(() {
      if (!_editing) _extraDraft = _input.text;
      _editingEntry = entry;
      _editingExercise = exercise;
      _error = null;
      _input.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    });
    _focus.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      _editingEntry = null;
      _editingExercise = null;
      _error = null;
      _input.value = TextEditingValue(
        text: _extraDraft,
        selection: TextSelection.collapsed(offset: _extraDraft.length),
      );
      _extraDraft = '';
    });
  }

  void _submit() {
    if (!_active) return;
    final value = _input.text.trim();
    if (value.isEmpty) {
      setState(() => _error = _editing ? 'Enter a result.' : 'Enter an entry.');
      _focus.requestFocus();
      return;
    }
    if (_editingEntry case final entry?) {
      _replaceEntry(entry, value);
    } else if (_editingExercise case final exercise?) {
      _logExercise(exercise, value);
    } else {
      _append(title: value);
    }
    if (_editing) {
      _cancelEdit();
      _focus.unfocus();
    } else {
      _input.clear();
    }
  }

  void _replaceEntry(GymLogEntry entry, String value) {
    final session = _session!;
    final updated = GymLogEntry(
      id: entry.id,
      title: entry.exerciseId == null ? value : entry.title,
      loggedAt: entry.loggedAt,
      actual: entry.exerciseId == null ? null : value,
      exerciseId: entry.exerciseId,
    );
    _update(
      session._withEntries([
        for (final existing in session.entries)
          existing.id == entry.id ? updated : existing,
      ]),
    );
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Semantics(
      header: true,
      child: Text(title, style: sectionHeadingStyle),
    ),
  );

  Widget _choice({
    required String title,
    required String detail,
    required IconData icon,
    required bool planned,
  }) {
    return Material(
      color: raisedPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        leading: Icon(icon, color: accent),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(detail, style: const TextStyle(color: muted)),
        trailing: const Icon(Icons.chevron_right_rounded, color: muted),
        onTap: () => _begin(planned),
      ),
    );
  }

  Widget _planRow(_Exercise exercise) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 285 ||
              MediaQuery.textScalerOf(context).scale(14) > 18;
          final detail = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                exercise.title,
                style: const TextStyle(
                  color: ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(exercise.target, style: const TextStyle(color: muted)),
            ],
          );
          final actions = Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: 'Log ${exercise.title} as planned',
                child: TextButton(
                  onPressed: () => _logExercise(exercise, exercise.target),
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    backgroundColor: softAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(44, 44),
                  ),
                  child: const Text('Log as planned'),
                ),
              ),
              IconButton(
                tooltip: 'Enter actual for ${exercise.title}',
                onPressed: () => _edit(exercise: exercise),
                icon: const Icon(Icons.edit_outlined, color: muted, size: 18),
              ),
            ],
          );
          return compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [detail, const SizedBox(height: 6), actions],
                )
              : Row(
                  children: [
                    Expanded(child: detail),
                    const SizedBox(width: 6),
                    actions,
                  ],
                );
        },
      ),
    );
  }

  Widget _plan(List<_Exercise> pending) {
    return Material(
      color: raisedPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: line),
      ),
      child: Column(
        children: [
          for (var index = 0; index < pending.length; index++) ...[
            if (index != 0) const Divider(height: 1),
            _planRow(pending[index]),
          ],
        ],
      ),
    );
  }

  Widget _entryRow(GymLogEntry entry, {required bool editable}) {
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 0, right: 1),
      title: Text(
        entry.title,
        style: const TextStyle(color: ink, fontWeight: FontWeight.w600),
      ),
      subtitle: entry.actual == null
          ? null
          : Text(entry.actual!, style: const TextStyle(color: muted)),
      trailing: editable
          ? IconButton(
              tooltip: 'Edit ${entry.title}',
              onPressed: () => _edit(entry: entry),
              icon: const Icon(Icons.edit_outlined, color: muted, size: 18),
            )
          : null,
    );
  }

  Widget _entries(GymSession session, {required bool editable}) {
    if (session.entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 7),
        child: Text('No entries yet.', style: TextStyle(color: muted)),
      );
    }
    return Column(
      children: [
        for (final entry in session.entries) ...[
          _entryRow(entry, editable: editable),
          const Divider(height: 1),
        ],
      ],
    );
  }

  Widget _inputBar(double side) {
    final exercise =
        _editingExercise?.title ??
        (_editingEntry?.exerciseId == null ? null : _editingEntry?.title);
    final radius = BorderRadius.circular(13);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: line)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 8, side, 13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_editing)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      exercise == null ? 'Edit entry' : 'Actual · $exercise',
                      style: const TextStyle(
                        color: ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel edit',
                    onPressed: () {
                      _cancelEdit();
                      _focus.unfocus();
                    },
                    icon: const Icon(
                      Icons.close_rounded,
                      color: muted,
                      size: 18,
                    ),
                  ),
                ],
              ),
            TextField(
              controller: _input,
              focusNode: _focus,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onEditingComplete: () {},
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText: _editing ? 'Enter actual' : 'Add an exercise or note',
                errorText: _error,
                filled: true,
                fillColor: raisedPaper,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                border: OutlineInputBorder(borderRadius: radius),
                enabledBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: const BorderSide(color: line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: const BorderSide(color: accent, width: 1.5),
                ),
                suffixIcon: Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton.filled(
                    tooltip: _editing ? 'Save entry' : 'Log entry',
                    onPressed: _submit,
                    icon: Icon(
                      _editing
                          ? Icons.check_rounded
                          : Icons.arrow_upward_rounded,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final logged = {
      for (final entry in session?.entries ?? []) entry.exerciseId,
    };
    final pending = session?.planned == true
        ? _exercises.where((exercise) => !logged.contains(exercise.id)).toList()
        : const <_Exercise>[];
    final side = MediaQuery.sizeOf(context).width < 600 ? 20.0 : 30.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gym session'),
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        actions: [
          if (_active)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 7),
              child: TextButton(
                onPressed: _finish,
                child: const Text('Finish'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(side, 18, side, 22),
                    children: [
                      if (session != null) ...[
                        if (session.finished) ...[
                          _heading('Session complete'),
                          _entries(session, editable: false),
                          const SizedBox(height: 24),
                        ] else ...[
                          if (pending.isNotEmpty) ...[
                            _heading('Plan'),
                            _plan(pending),
                            const SizedBox(height: 23),
                          ],
                          _heading('Session log'),
                          _entries(session, editable: true),
                        ],
                      ],
                      if (!_active) ...[
                        if (session != null) _heading('Start another session'),
                        _choice(
                          title: 'Planned session',
                          detail: 'Treadmill and bench press',
                          icon: Icons.checklist_rounded,
                          planned: true,
                        ),
                        const SizedBox(height: 8),
                        _choice(
                          title: 'Freestyle',
                          detail: 'Log exercises as you go',
                          icon: Icons.notes_rounded,
                          planned: false,
                        ),
                      ],
                    ],
                  ),
                ),
                if (_active) _inputBar(side),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
