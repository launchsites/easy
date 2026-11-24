# Local workspace search

The search index uses workspace records in memory. Index building and querying use local Dart code. Flutter native clients build larger indexes on a worker isolate.

## Workspace integration

- Pass feature-visible `SearchDocument` records to `buildSearchIndex`. Include only titles, bodies, categories and dates that the user may see in the current workspace. External calendar copies inherit their import visibility and sensitive module records inherit their own feature permissions. The index treats every supplied field as searchable.
- Cache the completed or pending index by workspace identity, content revision and visibility revision. Replace the future when any of those inputs changes. An optional `allowedCategories` set further restricts the dialog and excludes unclassified records while present.
- With `WorkspaceSearchDialog`, use the returned `SearchDocument.key` to resolve the live record in the current workspace and check its visibility before opening it. `SearchPreferences` stores local typed record keys for the favourites explicitly set by the user and the most recent 30 opened results. Query text stays in the dialog. Unavailable saved references stay out of the visible groups.

[`SearchDocument` and `SearchPreferences`](../lib/search/search_models.dart) · [`WorkspaceSearchDialog`](../lib/search/workspace_search_dialog.dart)

## Matching and coverage

Search uses case-insensitive word prefixes across titles, bodies and categories. `title:`, `body:` and `category:` scope terms to fields. `type:task`, `type:event` and `type:note` filter by record type, as do the visible type chips. Double quotes group several terms under one field. Latin accents fold for matching, and East Asian scripts use character tokens. Titles and exact words receive ranking weight. Record date and key break ties consistently.

The index covers full supplied bodies. The first 12,000 UTF-16 code units can provide a contextual excerpt. Excerpt length is capped at 158 code units and search returns up to 100 results. A query considers up to 32 distinct field terms and inspects at most 128 vocabulary entries per prefix. Broad prefixes can be refined by typing another character.

The 43 passing tests cover search behaviour and layout together. Fixtures include 100,000 tasks, calendar events and notes, a seeded comparison against direct matching, multi-script and absent terms, incomplete data, scoped favourites, and compact interaction. The shared layout matrix exercises six workspace pages at six viewport and text scale combinations. [Search tests](../test/search_index_test.dart) · [Layout matrix](../test/module_layout_test.dart)

```sh
TZ=Europe/London flutter test --no-pub test/search_index_test.dart test/module_layout_test.dart
dart analyze lib/search test/search_index_test.dart test/module_layout_test.dart tool/benchmark/search_scale.dart
```

## Synthetic scale run

The AOT fixture builds a fresh 100,000-record index and runs 51 measured requests for each case after one warm-up. The shared Linux x64 host has an AMD EPYC 9V74 and a four-CPU quota. The second run pins the process to one CPU. RSS is measured at the end of the run.

| CPU affinity | Build | Scoped p50 / p95 | Broad p50 / p95 | Missing p50 / p95 | RSS |
|---|---:|---:|---:|---:|---:|
| Default | 1,975 ms | 0.030 / 0.065 ms | 10.229 / 37.128 ms | 0.002 / 0.002 ms | 118 MiB |
| One pinned CPU | 4,249 ms | 0.031 / 0.129 ms | 18.197 / 55.229 ms | 0.002 / 0.003 ms | 103 MiB |

These are index and query timings under shared host load. Production desktop and mobile input latency also includes the dialog and rendering. [Scale fixture](../tool/benchmark/search_scale.dart)

```sh
easy_search_build=$(mktemp -d)
dart compile exe tool/benchmark/search_scale.dart -o "$easy_search_build/search-scale"
"$easy_search_build/search-scale"
taskset -c 0 "$easy_search_build/search-scale"
```
