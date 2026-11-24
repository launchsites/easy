import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'automation_models.dart';

typedef AutomationChange = Future<AutomationData> Function(
  AutomationData Function(AutomationData current) update,
);

class AutomationPage extends StatefulWidget {
  const AutomationPage({
    required this.data,
    required this.onChange,
    this.onAcceptDraft,
    this.categories = const {},
    this.enabledTriggers,
    this.clock,
    super.key,
  });

  final AutomationData data;
  final AutomationChange onChange;
  final Future<AutomationData> Function(String id)? onAcceptDraft;
  final Map<String, String> categories;
  final Set<AutomationTrigger>? enabledTriggers;
  final DateTime Function()? clock;

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

enum _AutomationView { rules, outbox, history }

class _AutomationPageState extends State<AutomationPage> {
  late AutomationData _data = widget.data;
  _AutomationView _view = _AutomationView.rules;
  bool _saving = false;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void didUpdateWidget(covariant AutomationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_saving && !identical(widget.data, oldWidget.data)) {
      _data = widget.data;
    }
  }

  Future<bool> _apply(Future<AutomationData> Function() change) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      final next = await change();
      if (mounted) setState(() => _data = next);
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException
                  ? error.message
                  : 'The change could not be saved. Try again.',
            ),
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _update(AutomationData Function(AutomationData) update) =>
      _apply(() => widget.onChange(update));

  Future<void> _edit([AutomationRule? rule]) async {
    final now = _now;
    final ruleId =
        rule?.id ?? 'rule-${now.microsecondsSinceEpoch}-${_data.rules.length}';
    await showDialog<void>(
      context: context,
      builder: (context) => _AutomationRuleEditor(
        previous: rule,
        id: ruleId,
        categories: widget.categories,
        enabledTriggers: widget.enabledTriggers,
        clock: () => _now,
        onSave: (replacement) =>
            _update((current) => current.withRule(replacement)),
        onRemove: rule == null
            ? null
            : () => _update((current) => current.withoutRule(rule.id)),
      ),
    );
  }

  Future<void> _review(AutomationDraft draft) async {
    final accept = widget.onAcceptDraft;
    final choice = await showDialog<AutomationDraftStatus>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(draft.action.kind.label),
        content: SizedBox(
          width: 410,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectionArea(child: Text(draft.action.text)),
              const SizedBox(height: 12),
              Text(
                [
                  draft.ruleName,
                  draft.event.trigger.label,
                  if (draft.event.sourceTitle case final source?
                      when source.isNotEmpty)
                    source,
                  if (draft.action.category case final category?)
                    widget.categories[category] ?? category,
                ].join(' · '),
                style: contentMetadataStyle,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, AutomationDraftStatus.dismissed),
            child: const Text('Dismiss draft'),
          ),
          if (accept != null)
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, AutomationDraftStatus.accepted),
              child: Text(
                draft.action.kind == AutomationActionKind.taskDraft
                    ? 'Add task'
                    : 'Add note',
              ),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == AutomationDraftStatus.accepted && accept != null) {
      await _apply(() => accept(draft.id));
    } else {
      final now = _now;
      await _update(
        (current) => current.reviewDraft(draft.id, status: choice, now: now),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _data.pending.toList().reversed.toList();
    final history =
        _data.drafts
            .where((draft) => draft.status != AutomationDraftStatus.pending)
            .toList()
          ..sort((a, b) => b.reviewedAt!.compareTo(a.reviewedAt!));
    return Scaffold(
      appBar: AppBar(title: const Text('Automations')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(21, 6, 21, 9),
                  sliver: SliverToBoxAdapter(
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 4,
                      children: [
                        for (final (view, label) in [
                          (_AutomationView.rules, 'Rules'),
                          (
                            _AutomationView.outbox,
                            pending.isEmpty
                                ? 'Outbox'
                                : 'Outbox (${pending.length})',
                          ),
                          (_AutomationView.history, 'History'),
                        ])
                          ChoiceChip(
                            label: Text(label),
                            selected: _view == view,
                            onSelected: _saving
                                ? null
                                : (_) => setState(() => _view = view),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(21, 0, 21, 30),
                  sliver: switch (_view) {
                    _AutomationView.rules => _rules(),
                    _AutomationView.outbox => _drafts(pending, reviewed: false),
                    _AutomationView.history => _drafts(history, reviewed: true),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rules() => SliverList(
    delegate: SliverChildBuilderDelegate((context, index) {
      if (index == 0) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable automations'),
              subtitle: const Text(
                'Matching events create drafts for review.',
                style: contentMetadataStyle,
              ),
              value: _data.enabled,
              onChanged: _saving
                  ? null
                  : (value) {
                      final now = _now;
                      _update((current) => current.withEnabled(value, now));
                    },
            ),
            const SizedBox(height: 7),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed:
                    _saving || _data.rules.length >= AutomationData.maxRules
                    ? null
                    : _edit,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New rule'),
              ),
            ),
            if (_data.rules.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: Text('No rules yet.', style: contentMetadataStyle),
              ),
          ],
        );
      }
      final rule = _data.rules[index - 1];
      final supported = widget.enabledTriggers?.contains(rule.trigger) ?? true;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          rule.name,
          style: contentTitleStyle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            rule.trigger.label,
            rule.action.kind.label,
            if (!supported) 'Unavailable here',
            if (!rule.enabled) 'Off',
          ].join(' · '),
          style: contentMetadataStyle,
        ),
        trailing: const Icon(Icons.chevron_right_rounded, color: muted),
        onTap: _saving ? null : () => _edit(rule),
      );
    }, childCount: _data.rules.length + 1),
  );

  Widget _drafts(List<AutomationDraft> drafts, {required bool reviewed}) {
    if (drafts.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 17),
          child: Text(
            reviewed
                ? 'No reviewed drafts yet.'
                : 'No drafts waiting for review.',
            style: contentMetadataStyle,
          ),
        ),
      );
    }
    final labels = MaterialLocalizations.of(context);
    return SliverList.separated(
      itemCount: drafts.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) {
        final draft = drafts[index];
        return ListTile(
          key: ValueKey(draft.id),
          contentPadding: EdgeInsets.zero,
          title: Text(
            draft.action.text,
            style: contentTitleStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              draft.ruleName,
              labels.formatMediumDate(
                (draft.reviewedAt ?? draft.createdAt).toLocal(),
              ),
              if (reviewed)
                draft.status == AutomationDraftStatus.accepted
                    ? 'Added'
                    : 'Dismissed',
            ].join(' · '),
            style: contentMetadataStyle,
          ),
          trailing: reviewed
              ? null
              : const Icon(Icons.chevron_right_rounded, color: muted),
          onTap: reviewed || _saving ? null : () => _review(draft),
        );
      },
    );
  }
}

class _AutomationRuleEditor extends StatefulWidget {
  const _AutomationRuleEditor({
    required this.previous,
    required this.id,
    required this.categories,
    required this.enabledTriggers,
    required this.clock,
    required this.onSave,
    required this.onRemove,
  });

  final AutomationRule? previous;
  final String id;
  final Map<String, String> categories;
  final Set<AutomationTrigger>? enabledTriggers;
  final DateTime Function() clock;
  final Future<bool> Function(AutomationRule rule) onSave;
  final Future<bool> Function()? onRemove;

  @override
  State<_AutomationRuleEditor> createState() => _AutomationRuleEditorState();
}

class _AutomationRuleEditorState extends State<_AutomationRuleEditor> {
  late final _name = TextEditingController(text: widget.previous?.name);
  late final _text = TextEditingController(text: widget.previous?.action.text);
  List<AutomationTrigger> get _available => AutomationTrigger.values
      .where((trigger) => widget.enabledTriggers?.contains(trigger) ?? true)
      .toList();
  late AutomationTrigger _trigger =
      widget.previous?.trigger ??
      _available.firstOrNull ??
      AutomationTrigger.taskCompleted;
  late AutomationActionKind _kind =
      widget.previous?.action.kind ?? AutomationActionKind.taskDraft;
  late String? _condition = widget.previous?.condition.category;
  late String? _category = widget.previous?.action.category;
  late bool _enabled = widget.previous?.enabled ?? false;
  late final _weekdays = {...?widget.previous?.condition.weekdays};
  late int? _start = widget.previous?.condition.startMinute;
  late int? _end = widget.previous?.condition.endMinute;
  var _advanced = false;
  var _busy = false;
  String? _issue;

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    final clicked = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove rule?'),
        content: Text(widget.previous!.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || clicked != true) return;
    setState(() => _busy = true);
    final removed = await widget.onRemove!();
    if (!mounted) return;
    if (removed) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _text.text.trim().isEmpty) {
      setState(() => _issue = 'Enter a name and draft text.');
      return;
    }
    if (_enabled && !_available.contains(_trigger)) {
      setState(
        () => _issue = 'Choose an available trigger before enabling this rule.',
      );
      return;
    }
    final AutomationRule rule;
    try {
      rule = AutomationRule(
        id: widget.id,
        name: name,
        trigger: _trigger,
        condition: AutomationCondition(
          category: _condition,
          weekdays: _weekdays,
          startMinute: _start,
          endMinute: _end,
        ),
        action: AutomationAction(
          kind: _kind,
          text: _text.text,
          category: _category,
        ),
        enabledSince: _enabled ? widget.clock() : null,
      );
    } on FormatException catch (error) {
      setState(() => _issue = error.message);
      return;
    }
    setState(() {
      _busy = true;
      _issue = null;
    });
    FocusScope.of(context).unfocus();
    final saved = await widget.onSave(rule);
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _issue = 'The rule could not be saved.';
      });
    }
  }

  Future<void> _time({required bool start}) async {
    final minute = (start ? _start : _end) ?? (start ? 9 * 60 : 18 * 60);
    final choice = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    if (mounted && choice != null) {
      setState(() {
        final selected = choice.hour * 60 + choice.minute;
        if (start) {
          _start = selected;
          _end ??= (selected + 60) % 1440;
        } else {
          _end = selected;
          _start ??= (selected + 1380) % 1440;
        }
      });
    }
  }

  String _timeLabel(int? minute) => minute == null
      ? 'Any time'
      : MaterialLocalizations.of(context).formatTimeOfDay(
          TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        );

  Widget _categoryPicker({
    required String label,
    required String empty,
    required String? selected,
    required ValueChanged<String?> onChanged,
  }) {
    final options = {
      ...widget.categories,
      if (selected != null && !widget.categories.containsKey(selected))
        selected: selected,
    };
    if (options.isEmpty) return const SizedBox.shrink();
    return DropdownButtonFormField<({String? category})>(
      initialValue: (category: selected),
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(value: (category: null), child: Text(empty)),
        for (final option in options.entries)
          DropdownMenuItem(
            value: (category: option.key),
            child: Text(option.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy ? null : (value) => onChanged(value?.category),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.previous == null ? 'New rule' : 'Edit rule'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Rule name'),
              textCapitalization: TextCapitalization.sentences,
            ),
            DropdownButtonFormField<AutomationTrigger>(
              initialValue: _trigger,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'When'),
              items: [
                for (final trigger in {..._available, _trigger})
                  DropdownMenuItem(
                    value: trigger,
                    child: Text(trigger.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (trigger) => setState(() => _trigger = trigger ?? _trigger),
            ),
            _categoryPicker(
              label: 'Trigger category',
              empty: 'Any category',
              selected: _condition,
              onChanged: (value) => setState(() => _condition = value),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _advanced = !_advanced),
              child: Text(
                _advanced ? 'Hide time conditions' : 'Time conditions',
              ),
            ),
            if (_advanced) ...[
              Wrap(
                spacing: 5,
                runSpacing: 4,
                children: [
                  for (final (index, label) in [
                    'Mon',
                    'Tue',
                    'Wed',
                    'Thu',
                    'Fri',
                    'Sat',
                    'Sun',
                  ].indexed)
                    FilterChip(
                      label: Text(label),
                      selected: _weekdays.contains(index + 1),
                      onSelected: _busy
                          ? null
                          : (on) => setState(() {
                              if (on) {
                                _weekdays.add(index + 1);
                              } else {
                                _weekdays.remove(index + 1);
                              }
                            }),
                    ),
                ],
              ),
              Wrap(
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _time(start: true),
                    child: Text('From ${_timeLabel(_start)}'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _time(start: false),
                    child: Text('To ${_timeLabel(_end)}'),
                  ),
                  if (_start != null)
                    IconButton(
                      tooltip: 'Clear time window',
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _start = null;
                              _end = null;
                            }),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ],
            DropdownButtonFormField<AutomationActionKind>(
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Draft type'),
              items: [
                for (final kind in AutomationActionKind.values)
                  DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: _busy
                  ? null
                  : (kind) => setState(() => _kind = kind ?? _kind),
            ),
            _categoryPicker(
              label: 'Draft category',
              empty: 'Uncategorised',
              selected: _category,
              onChanged: (value) => setState(() => _category = value),
            ),
            TextField(
              controller: _text,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Draft text'),
              textCapitalization: TextCapitalization.sentences,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Rule enabled'),
              value: _enabled,
              onChanged: _busy
                  ? null
                  : (enabled) => setState(() => _enabled = enabled),
            ),
            if (_issue case final issue?)
              Text(
                issue,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.onRemove != null)
          TextButton(
            onPressed: _busy ? null : _remove,
            child: const Text('Remove rule'),
          ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save rule'),
        ),
      ],
    ),
  );
}
