import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'note_model.dart';
import 'note_preview.dart';

typedef DesktopNoteSave = Future<NoteItem> Function(
  NoteItem expected,
  String title,
  String body,
);

enum _SaveStatus { idle, pending, saving, failed }

/// Owns drafts for the lifetime of the workspace, including when the editor
/// goes offscreen or another note is selected during a save.
class DesktopNoteEdits extends ChangeNotifier {
  DesktopNoteEdits({
    required this._save,
    this._debounce = const Duration(milliseconds: 500),
  });

  final DesktopNoteSave _save;
  final Duration _debounce;
  final _drafts = <String, _Draft>{};
  Future<void> _writes = Future.value();
  var _disposed = false;

  ({String title, String body}) _observe(NoteItem note) {
    final draft = _drafts[note.id];
    if (draft != null) {
      if (identical(note, draft.observed) ||
          draft.dirty ||
          draft.operation != null) {
        draft.observed = note;
        return (title: draft.title, body: draft.body);
      }
      _drafts.remove(note.id);
    }
    return (title: note.title, body: note.body);
  }

  _SaveStatus _status(String id) {
    final draft = _drafts[id];
    if (draft == null) return _SaveStatus.idle;
    if (draft.operation != null) return _SaveStatus.saving;
    if (draft.failed) return _SaveStatus.failed;
    return draft.dirty ? _SaveStatus.pending : _SaveStatus.idle;
  }

  void _update(NoteItem note, String title, String body) {
    if (_disposed) return;
    final draft = _drafts.putIfAbsent(note.id, () => _Draft(note));
    if (draft.title == title && draft.body == body) return;
    draft.title = title;
    draft.body = body;
    draft.failed = false;
    _schedule(draft);
    _notify();
  }

  void _schedule(_Draft draft) {
    draft.timer?.cancel();
    draft.timer = null;
    if (_disposed || !draft.dirty || draft.failed) return;
    draft.timer = Timer(_debounce, () {
      draft.timer = null;
      unawaited(_saveOnce(draft));
    });
  }

  /// Attempts every selected draft and returns false if any remains unsaved.
  /// Edits made during an in-flight write are saved against its result.
  Future<bool> flush([String? id]) async {
    if (_disposed) return false;
    final drafts = id == null ? _drafts.values.toList() : [?_drafts[id]];
    var completed = true;
    for (final draft in drafts) {
      while (draft.dirty || draft.operation != null) {
        draft.timer?.cancel();
        draft.timer = null;
        if (!await _saveOnce(draft)) {
          completed = false;
          break;
        }
      }
    }
    return completed;
  }

  Future<bool> _saveOnce(_Draft draft) {
    if (_disposed) return Future.value(false);
    if (draft.operation case final operation?) return operation;
    if (!draft.dirty) return Future.value(true);

    final operation = _writes
        .then((_) async {
          if (_disposed || !draft.dirty) return !draft.dirty;
          final title = draft.title;
          final body = draft.body;
          draft.failed = false;
          _notify();
          try {
            final saved = await _save(draft.persisted, title, body);
            if (saved.id != draft.persisted.id) {
              throw StateError('The saved note has another ID.');
            }
            draft.persisted = saved;
            if (draft.title == title && draft.body == body) {
              draft.title = saved.title;
              draft.body = saved.body;
            }
            return true;
          } catch (_) {
            draft.failed = draft.dirty;
            return !draft.failed;
          }
        })
        .whenComplete(() {
          draft.operation = null;
          if (!draft.dirty) {
            draft.timer?.cancel();
            draft.timer = null;
            if (identical(draft.persisted, draft.observed)) {
              _drafts.remove(draft.persisted.id);
            }
          } else if (draft.timer == null) {
            _schedule(draft);
          }
          _notify();
        });
    draft.operation = operation;
    _writes = operation.then((_) {});
    return operation;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final draft in _drafts.values) {
      draft.timer?.cancel();
    }
    super.dispose();
  }
}

class _Draft {
  _Draft(this.persisted)
    : observed = persisted,
      title = persisted.title,
      body = persisted.body;

  NoteItem persisted;
  NoteItem observed;
  String title;
  String body;
  bool failed = false;
  Timer? timer;
  Future<bool>? operation;

  bool get dirty => title != persisted.title || body != persisted.body;
}

class DesktopNoteEditor extends StatefulWidget {
  const DesktopNoteEditor({
    required this.note,
    required this.edits,
    this.targets = const [],
    this.onOpenLink,
    this.actions,
    this.autofocus = false,
    super.key,
  });

  final NoteItem note;
  final DesktopNoteEdits edits;
  final List<NoteTarget> targets;
  final ValueChanged<NoteLink>? onOpenLink;
  final Widget? actions;
  final bool autofocus;

  @override
  State<DesktopNoteEditor> createState() => _DesktopNoteEditorState();
}

class _DesktopNoteEditorState extends State<DesktopNoteEditor> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();
  var _preview = false;

  @override
  void initState() {
    super.initState();
    _loadNote();
    widget.edits.addListener(_updateStatus);
    _focusNewTitle();
  }

  @override
  void didUpdateWidget(covariant DesktopNoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.edits != widget.edits) {
      oldWidget.edits.removeListener(_updateStatus);
      widget.edits.addListener(_updateStatus);
    }
    if (oldWidget.note.id != widget.note.id ||
        oldWidget.edits != widget.edits) {
      unawaited(oldWidget.edits.flush(oldWidget.note.id));
      _preview = false;
      _focusNewTitle();
    }
    _loadNote();
  }

  void _loadNote() {
    final text = widget.edits._observe(widget.note);
    _replaceText(_title, text.title);
    _replaceText(_body, text.body);
  }

  void _replaceText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    final selection = controller.selection;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: selection.baseOffset.clamp(0, text.length),
        extentOffset: selection.extentOffset.clamp(0, text.length),
      ),
    );
  }

  void _focusNewTitle() {
    if (!widget.autofocus) return;
    final id = widget.note.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && id == widget.note.id) _titleFocus.requestFocus();
    });
  }

  void _updateStatus() {
    if (mounted) setState(() {});
  }

  void _edited() => widget.edits._update(widget.note, _title.text, _body.text);

  void _flush() => unawaited(widget.edits.flush(widget.note.id));

  TextSelection get _bodySelection {
    final selection = _body.selection;
    if (selection.isValid && selection.end <= _body.text.length) {
      return selection;
    }
    return TextSelection.collapsed(offset: _body.text.length);
  }

  void _wrapMarkdown(String before, String after) {
    if (_preview) return;
    final selection = _bodySelection;
    final content = _body.text.substring(selection.start, selection.end);
    _applyMarkdown(
      selection.start,
      selection.end,
      '$before$content$after',
      TextSelection(
        baseOffset: selection.start + before.length,
        extentOffset: selection.end + before.length,
      ),
    );
  }

  void _formatShortcut(String marker) {
    if (_bodyFocus.hasFocus) _wrapMarkdown(marker, marker);
  }

  void _prefixLines(String prefix) {
    if (_preview) return;
    final selection = _bodySelection;
    final text = _body.text;
    final start = selection.start == 0
        ? 0
        : text.lastIndexOf('\n', selection.start - 1) + 1;
    final endsAtLineStart =
        !selection.isCollapsed && text[selection.end - 1] == '\n';
    final end = endsAtLineStart ? selection.end - 1 : selection.end;
    final lines = text.substring(start, end).split('\n');
    _applyMarkdown(
      start,
      end,
      lines.map((line) => '$prefix$line').join('\n'),
      TextSelection(
        baseOffset: selection.start + prefix.length,
        extentOffset: selection.end + prefix.length * lines.length,
      ),
    );
  }

  void _applyMarkdown(
    int start,
    int end,
    String replacement,
    TextSelection selection,
  ) {
    _body.value = TextEditingValue(
      text: _body.text.replaceRange(start, end, replacement),
      selection: selection,
    );
    _bodyFocus.requestFocus();
    _edited();
  }

  void _togglePreview() {
    if (!_preview) _flush();
    setState(() => _preview = !_preview);
  }

  @override
  void dispose() {
    widget.edits.removeListener(_updateStatus);
    _flush();
    _title.dispose();
    _body.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.edits._status(widget.note.id);
    final style = IconButton.styleFrom(
      foregroundColor: ink,
      disabledForegroundColor: muted.withAlpha(0x70),
      minimumSize: const Size(40, 40),
      padding: EdgeInsets.zero,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _flush,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _flush,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _formatShortcut('**'),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _formatShortcut('**'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _formatShortcut('*'),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            _formatShortcut('*'),
      },
      child: Focus(
        onFocusChange: (focused) {
          if (!focused) _flush();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 16),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _title,
                    focusNode: _titleFocus,
                    onChanged: (_) => _edited(),
                    onSubmitted: (_) => _bodyFocus.requestFocus(),
                    textInputAction: TextInputAction.next,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 31,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.05,
                      height: 1.25,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Untitled',
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 2,
                    children: [
                      for (final (label, icon, action)
                          in <(String, IconData, VoidCallback)>[
                            (
                              'Bold',
                              Icons.format_bold_rounded,
                              () => _wrapMarkdown('**', '**'),
                            ),
                            (
                              'Italic',
                              Icons.format_italic_rounded,
                              () => _wrapMarkdown('*', '*'),
                            ),
                            (
                              'Heading',
                              Icons.title_rounded,
                              () => _prefixLines('## '),
                            ),
                            (
                              'Bulleted list',
                              Icons.format_list_bulleted_rounded,
                              () => _prefixLines('- '),
                            ),
                            (
                              'Inline code',
                              Icons.code_rounded,
                              () => _wrapMarkdown('`', '`'),
                            ),
                          ])
                        IconButton(
                          tooltip: label,
                          style: style,
                          icon: Icon(icon, size: 20),
                          onPressed: _preview ? null : action,
                        ),
                      IconButton(
                        tooltip: _preview
                            ? 'Write Markdown'
                            : 'Preview Markdown',
                        style: style,
                        icon: Icon(
                          _preview
                              ? Icons.edit_note_rounded
                              : Icons.visibility_outlined,
                          size: 20,
                        ),
                        onPressed: _togglePreview,
                      ),
                      ?widget.actions,
                    ],
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _preview
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: NotePreview(
                              note: widget.note.withContent(
                                title: _title.text,
                                body: _body.text,
                              ),
                              targets: widget.targets,
                              onOpenLink: widget.onOpenLink,
                            ),
                          )
                        : TextField(
                            controller: _body,
                            focusNode: _bodyFocus,
                            onChanged: (_) => _edited(),
                            expands: true,
                            minLines: null,
                            maxLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              color: ink,
                              fontSize: 16,
                              height: 1.7,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 15,
                              ),
                              hintText: 'Write a note…',
                            ),
                          ),
                  ),
                  if (status != _SaveStatus.idle)
                    Semantics(
                      liveRegion: true,
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        children: [
                          Text(switch (status) {
                            _SaveStatus.idle => '',
                            _SaveStatus.pending => 'Changes pending',
                            _SaveStatus.saving => 'Saving…',
                            _SaveStatus.failed => 'Changes could not be saved.',
                          }, style: contentMetadataStyle),
                          if (status == _SaveStatus.failed)
                            TextButton(
                              onPressed: _flush,
                              child: const Text('Retry'),
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
