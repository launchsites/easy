import 'dart:async';

import 'package:flutter/foundation.dart' show compute, setEquals;
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'search_index.dart';
import 'search_models.dart';

SearchIndex _buildIndex(List<SearchDocument> documents) =>
    SearchIndex.build(documents);

Future<SearchIndex> buildSearchIndex(List<SearchDocument> documents) {
  if (documents.length <= 400) {
    var textSize = 0;
    for (final item in documents) {
      textSize += item.title.length + item.body.length;
      if (textSize >= 512 * 1024) break;
    }
    if (textSize < 512 * 1024) return Future.sync(() => _buildIndex(documents));
  }
  return compute(_buildIndex, documents, debugLabel: 'Workspace search index');
}

class WorkspaceSearchDialog extends StatefulWidget {
  const WorkspaceSearchDialog({
    required this.index,
    required this.preferences,
    this.onPreferencesChanged,
    this.allowedCategories,
    this.initialQuery = '',
    super.key,
  });

  final Future<SearchIndex> index;
  final SearchPreferences preferences;
  final ValueChanged<SearchPreferences>? onPreferencesChanged;

  /// Supply only feature-visible records to the index. This optional scope
  /// narrows visible results further without discarding saved favourites.
  final Set<String>? allowedCategories;
  final String initialQuery;

  @override
  State<WorkspaceSearchDialog> createState() => _WorkspaceSearchDialogState();
}

class _WorkspaceSearchDialogState extends State<WorkspaceSearchDialog> {
  late final _input = TextEditingController(text: widget.initialQuery);
  late SearchPreferences _preferences = widget.preferences;
  late String _committedText = widget.initialQuery;
  SearchRecordKind? _kind;
  bool _onlyFavourites = false;
  Timer? _debounce;
  ({
    SearchIndex index,
    String text,
    SearchRecordKind? kind,
    bool onlyFavourites,
    SearchPreferences preferences,
  })?
  _memo;
  List<SearchHit> _hits = const [];

  @override
  void didUpdateWidget(covariant WorkspaceSearchDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.preferences, widget.preferences)) {
      _preferences = widget.preferences;
    }
    if (!setEquals(oldWidget.allowedCategories, widget.allowedCategories)) {
      _memo = null;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 85), () {
      if (mounted) setState(() => _committedText = value);
    });
  }

  WorkspaceSearchQuery _query([String? text]) => WorkspaceSearchQuery(
    text ?? _committedText,
    kinds: _kind == null ? null : {_kind!},
    allowedCategories: widget.allowedCategories,
    favouritesOnly: _onlyFavourites,
  );

  List<SearchHit> _results(SearchIndex index) {
    final signature = (
      index: index,
      text: _committedText,
      kind: _kind,
      onlyFavourites: _onlyFavourites,
      preferences: _preferences,
    );
    if (_memo != signature) {
      _hits = index.search(_query(), favourites: _preferences.favourites);
      _memo = signature;
    }
    return _hits;
  }

  void _applyPreferences(SearchPreferences value) {
    setState(() => _preferences = value);
    widget.onPreferencesChanged?.call(value);
  }

  void _open(SearchDocument document) {
    _applyPreferences(_preferences.opened(document.key));
    Navigator.pop(context, document);
  }

  void _enter(SearchIndex? index) {
    if (index == null) return;
    final text = _input.text;
    final SearchDocument? first;
    if (text.trim().isEmpty && _kind == null && !_onlyFavourites) {
      first = _groups(index).firstOrNull?.$2.firstOrNull;
    } else {
      first = index
          .search(_query(text), limit: 1, favourites: _preferences.favourites)
          .firstOrNull
          ?.document;
    }
    if (first != null) _open(first);
  }

  List<(String, List<SearchDocument>)> _groups(SearchIndex index) {
    final seen = <SearchKey>{};
    final query = _query();
    Iterable<SearchDocument> matches(Iterable<SearchKey> keys) sync* {
      for (final key in keys) {
        if (index.document(key) case final document?
            when index.includes(
                  document,
                  query,
                  favourites: _preferences.favourites,
                ) &&
                seen.add(key)) {
          yield document;
        }
      }
    }

    List<SearchDocument> from(Iterable<SearchKey> keys) =>
        matches(keys).take(12).toList();
    return [
      ('Favourites', from(_preferences.favourites)),
      ('Recent', from(_preferences.recent)),
      ('Pinned', from(index.pinnedKeys)),
    ].where((section) => section.$2.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
    child: SizedBox(
      width: 610,
      height: 520,
      child: LayoutBuilder(
        builder: (context, constraints) => FutureBuilder<SearchIndex>(
          future: widget.index,
          builder: (context, state) {
            final index = state.connectionState == ConnectionState.done
                ? state.data
                : null;
            final showFilters = index != null && constraints.maxHeight >= 230;
            final usingFilters = _kind != null || _onlyFavourites;
            final showResults =
                index != null &&
                (_committedText.trim().isNotEmpty || usingFilters);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(13, 7, 7, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          onChanged: _changed,
                          onSubmitted: (_) => _enter(index),
                          decoration: const InputDecoration(
                            labelText: 'Search workspace',
                            prefixIcon: Icon(Icons.search_rounded, size: 20),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close search',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                if (showFilters)
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(15, 2, 15, 7),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (kind, label) in [
                            (null, 'All'),
                            for (final value in SearchRecordKind.values)
                              if (index.kinds.contains(value))
                                (value, value.collectionLabel),
                          ])
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 6),
                              child: ChoiceChip(
                                label: Text(label),
                                selected: _kind == kind,
                                onSelected: (_) => setState(() => _kind = kind),
                              ),
                            ),
                          if (_preferences.favourites.isNotEmpty ||
                              _onlyFavourites)
                            FilterChip(
                              label: const Text('Favourites'),
                              selected: _onlyFavourites,
                              onSelected: (value) =>
                                  setState(() => _onlyFavourites = value),
                            ),
                        ],
                      ),
                    ),
                  ),
                const Divider(),
                Expanded(
                  child: switch (index) {
                    final visible? when showResults => _searchResults(visible),
                    final visible? => _suggested(visible),
                    null when state.hasError => const _SearchStatus(
                      'Search could not be prepared.',
                    ),
                    null => const Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  },
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _searchResults(SearchIndex index) {
    final hits = _results(index);
    if (hits.isEmpty) return const _SearchStatus('No matching records.');
    return ListView.separated(
      padding: const EdgeInsetsDirectional.fromSTEB(13, 4, 13, 14),
      itemCount: hits.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) =>
          _record(hits[index].document, hits[index].snippet),
    );
  }

  Widget _suggested(SearchIndex index) {
    final groups = _groups(index);
    if (groups.isEmpty) {
      return const _SearchStatus('Search titles, notes, or categories.');
    }
    return ListView(
      padding: const EdgeInsetsDirectional.fromSTEB(13, 4, 13, 15),
      children: [
        for (final (title, documents) in groups) ...[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(5, 12, 3, 4),
            child: Semantics(
              header: true,
              child: Text(title, style: sectionHeadingStyle),
            ),
          ),
          for (final document in documents)
            _record(document, searchSnippet(document.body)),
        ],
      ],
    );
  }

  Widget _record(SearchDocument document, String snippet) {
    final favourite = _preferences.favourites.contains(document.key);
    final labels = MaterialLocalizations.of(context);
    final description = [
      document.key.kind.label,
      if (document.categoryName ?? document.categoryId case final category?
          when category.isNotEmpty)
        category,
      if (document.date case final date?)
        labels.formatMediumDate(date.toLocal()),
    ].join(' · ');
    return ListTile(
      key: ValueKey(document.key),
      contentPadding: const EdgeInsetsDirectional.only(start: 5),
      leading: Icon(_icon(document.key.kind), size: 20, color: accent),
      title: Row(
        children: [
          if (document.pinned)
            const Padding(
              padding: EdgeInsetsDirectional.only(end: 4),
              child: Icon(
                Icons.push_pin_outlined,
                size: 15,
                semanticLabel: 'Pinned',
                color: muted,
              ),
            ),
          Expanded(
            child: Text(
              document.title,
              style: contentTitleStyle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        snippet.isEmpty ? description : '$description\n$snippet',
        maxLines: snippet.isEmpty ? 2 : 3,
        overflow: TextOverflow.ellipsis,
        style: contentMetadataStyle,
      ),
      isThreeLine: snippet.isNotEmpty,
      trailing: IconButton(
        tooltip: favourite ? 'Remove from favourites' : 'Add to favourites',
        isSelected: favourite,
        icon: const Icon(Icons.star_border_rounded, size: 20, color: muted),
        selectedIcon: const Icon(Icons.star_rounded, size: 20, color: accent),
        onPressed: () => _applyPreferences(
          _preferences.withFavourite(document.key, !favourite),
        ),
      ),
      onTap: () => _open(document),
    );
  }
}

IconData _icon(SearchRecordKind kind) => switch (kind) {
  SearchRecordKind.task => Icons.check_box_outlined,
  SearchRecordKind.event => Icons.calendar_today_outlined,
  SearchRecordKind.note => Icons.description_outlined,
  SearchRecordKind.activity => Icons.timer_outlined,
  SearchRecordKind.workout => Icons.fitness_center_outlined,
  SearchRecordKind.meal => Icons.restaurant_outlined,
};

class _SearchStatus extends StatelessWidget {
  const _SearchStatus(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Text(text, style: contentMetadataStyle),
  );
}
