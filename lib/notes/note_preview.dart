import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'note_model.dart';

const _previewLimit = 64 * 1024;
const _lineLimit = 512;

typedef _MarkdownNote = ({
  List<md.Node> blocks,
  List<NoteLink> links,
  bool shortened,
});

_MarkdownNote _parseMarkdown(String source) {
  var end = source.length < _previewLimit ? source.length : _previewLimit;
  var start = 0;
  for (var line = 0; line < _lineLimit && start < end; line++) {
    final next = source.indexOf('\n', start);
    if (next < 0 || next >= end) break;
    start = next + 1;
    if (line == _lineLimit - 1) end = start;
  }
  final text = source.substring(0, end);
  final List<md.Node> blocks;
  try {
    blocks = md.Document(
      encodeHtml: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parse(text);
  } catch (_) {
    return (
      blocks: [md.Text(text)],
      links: const [],
      shortened: end < source.length,
    );
  }
  final links = <NoteLink>{};
  final pending = [...blocks.reversed];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is! md.Element) continue;
    if (node.tag == 'a') {
      final link = NoteLink.fromMarkdown(node.attributes['href']);
      if (link != null) links.add(link);
    }
    pending.addAll(node.children?.reversed ?? const []);
  }
  return (
    blocks: blocks,
    links: links.toList(),
    shortened: end < source.length,
  );
}

class NotePreview extends StatefulWidget {
  const NotePreview({
    required this.note,
    this.targets = const [],
    this.onOpenLink,
    super.key,
  });

  final NoteItem note;
  final List<NoteTarget> targets;
  final ValueChanged<NoteLink>? onOpenLink;

  @override
  State<NotePreview> createState() => _NotePreviewState();
}

class _NotePreviewState extends State<NotePreview> {
  late Future<_MarkdownNote> _parsed;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant NotePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.note.body != oldWidget.note.body) _parse();
  }

  void _parse() {
    final text = widget.note.body;
    _parsed = text.length <= 4096
        ? Future.value(_parseMarkdown(text))
        : compute(_parseMarkdown, text, debugLabel: 'note preview');
  }

  @override
  Widget build(BuildContext context) {
    final known = {for (final target in widget.targets) target.link: target};
    final callback = widget.onOpenLink;
    return FutureBuilder<_MarkdownNote>(
      future: _parsed,
      builder: (context, snapshot) {
        final document = snapshot.data;
        final references = {
          ...widget.note.links,
          ...?document?.links.where(known.containsKey),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (snapshot.hasError)
              const Text(
                'Preview unavailable. The editor has the full note.',
                style: contentMetadataStyle,
              )
            else if (document == null ||
                snapshot.connectionState != ConnectionState.done)
              const LinearProgressIndicator(minHeight: 2)
            else if (document.blocks.isNotEmpty)
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final node in document.blocks)
                      _MarkdownBlock(
                        node: node,
                        targets: known,
                        onOpen: callback,
                      ),
                    if (document.shortened)
                      const Text(
                        'Preview shortened. The editor has the full note.',
                        style: contentMetadataStyle,
                      ),
                  ],
                ),
              ),
            if (references.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Linked records', style: sectionHeadingStyle),
              for (final link in references)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    link.kind == NoteLinkKind.task
                        ? Icons.check_box_outlined
                        : Icons.calendar_today_outlined,
                    size: 19,
                    color: accent,
                  ),
                  title: Text(
                    known[link]?.title ?? link.title ?? link.kind.label,
                    style: contentTitleStyle,
                  ),
                  subtitle: Text(
                    known.containsKey(link)
                        ? link.kind.label
                        : 'Unavailable ${link.kind.label.toLowerCase()}',
                    style: contentMetadataStyle,
                  ),
                  trailing: known.containsKey(link) && callback != null
                      ? const Icon(Icons.chevron_right_rounded, color: muted)
                      : null,
                  onTap: known.containsKey(link) && callback != null
                      ? () => callback(link)
                      : null,
                ),
            ],
          ],
        );
      },
    );
  }
}

class _MarkdownBlock extends StatelessWidget {
  const _MarkdownBlock({
    required this.node,
    required this.targets,
    required this.onOpen,
    this.depth = 0,
  });

  final md.Node node;
  final Map<NoteLink, NoteTarget> targets;
  final ValueChanged<NoteLink>? onOpen;
  final int depth;

  Widget _inline(List<md.Node> children, [TextStyle? style]) => _MarkdownInline(
    nodes: children,
    targets: targets,
    onOpen: onOpen,
    style: style ?? const TextStyle(color: ink, height: 1.52),
  );

  Widget _nested(List<md.Node> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final node in children)
        _MarkdownBlock(
          node: node,
          targets: targets,
          onOpen: onOpen,
          depth: depth + 1,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final node = this.node;
    if (node is! md.Element || depth >= 12) {
      return _inline([md.Text(node.textContent)]);
    }
    final children = node.children ?? const <md.Node>[];
    final Widget body;
    switch (node.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        body = Semantics(
          header: true,
          child: _inline(
            children,
            sectionHeadingStyle.copyWith(fontSize: node.tag == 'h1' ? 23 : 18),
          ),
        );
      case 'pre':
        body = DecoratedBox(
          decoration: BoxDecoration(
            color: raisedPaper,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Text(
              node.textContent.trimRight(),
              style: const TextStyle(
                color: ink,
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        );
      case 'blockquote':
        body = DecoratedBox(
          decoration: const BoxDecoration(
            border: BorderDirectional(start: BorderSide(color: line, width: 3)),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: _nested(children),
          ),
        );
      case 'ol' || 'ul':
        final ordered = node.tag == 'ol';
        final start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, item) in children.indexed)
              _listItem(item, ordered ? '${start + index}.' : '•'),
          ],
        );
      case 'hr':
        body = const Divider();
      case 'p':
        body = _inline(children);
      default:
        body = _inline([md.Text(node.textContent)]);
    }
    return Padding(padding: const EdgeInsets.only(bottom: 9), child: body);
  }

  Widget _listItem(md.Node node, String marker) {
    if (node is! md.Element) return _inline([node]);
    final children = node.children ?? const <md.Node>[];
    final check = children
        .whereType<md.Element>()
        .where((element) => element.tag == 'input')
        .firstOrNull;
    final isNested = children.whereType<md.Element>().any(
      (element) => const {'p', 'ul', 'ol', 'blockquote'}.contains(element.tag),
    );
    final filtered = [
      for (final node in children)
        if (node is! md.Element || node.tag != 'input') node,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (check == null)
            Text(marker, style: const TextStyle(color: muted, height: 1.52))
          else
            Icon(
              check.attributes.containsKey('checked')
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank_rounded,
              size: 17,
              color: accent,
              semanticLabel: check.attributes.containsKey('checked')
                  ? 'Checked'
                  : 'Unchecked',
            ),
          const SizedBox(width: 8),
          Expanded(child: isNested ? _nested(filtered) : _inline(filtered)),
        ],
      ),
    );
  }
}

class _MarkdownInline extends StatefulWidget {
  const _MarkdownInline({
    required this.nodes,
    required this.targets,
    required this.onOpen,
    required this.style,
  });

  final List<md.Node> nodes;
  final Map<NoteLink, NoteTarget> targets;
  final ValueChanged<NoteLink>? onOpen;
  final TextStyle style;

  @override
  State<_MarkdownInline> createState() => _MarkdownInlineState();
}

class _MarkdownInlineState extends State<_MarkdownInline> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: [for (final node in widget.nodes) _span(node, 0)],
      ),
    );
  }

  TextSpan _span(md.Node node, int depth) {
    if (node is! md.Element || depth >= 24) {
      return TextSpan(text: node.textContent);
    }
    if (node.tag == 'a') {
      final link = NoteLink.fromMarkdown(node.attributes['href']);
      final target = widget.targets[link];
      final open = widget.onOpen;
      if (target == null || open == null) {
        return TextSpan(text: node.textContent);
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => open(target.link);
      _recognizers.add(recognizer);
      return TextSpan(
        text: node.textContent,
        style: const TextStyle(
          color: accent,
          decoration: TextDecoration.underline,
        ),
        recognizer: recognizer,
      );
    }
    if (node.tag == 'img') return TextSpan(text: node.attributes['alt'] ?? '');
    if (node.tag == 'br') return const TextSpan(text: '\n');
    return TextSpan(
      style: switch (node.tag) {
        'strong' => const TextStyle(fontWeight: FontWeight.w700),
        'em' => const TextStyle(fontStyle: FontStyle.italic),
        'del' => const TextStyle(decoration: TextDecoration.lineThrough),
        'code' => const TextStyle(fontFamily: 'monospace'),
        _ => null,
      },
      children: [
        for (final child in node.children ?? const <md.Node>[])
          _span(child, depth + 1),
      ],
    );
  }
}
