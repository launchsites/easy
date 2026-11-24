# Health, Review, and Insights validation

Validation ran on Linux x64 with Flutter 3.50.1 and Dart 3.14.0. The fixtures use synthetic records and a Europe/London clock.

## Health and daily review

- Health coverage includes kg/lb and cm/in conversions, preservation of entered units, persistence failure and retry, dated limitation scopes, explicit resolution, and confirmation before any single-session skips. A limitation remains open after its review date until the user marks it resolved. [Health tests](../test/health_test.dart)
- Review coverage includes unioned busy windows, a DST day boundary, preservation of earlier reflections, an opened saved reflection, habit history across pauses and schedule changes, and explicit confirmation for moving a flexible task. Monthly History can use a cached activity lookup. [Review tests](../test/review_test.dart)
- Workout notes and reflection text are selectable. Expanded records were exercised at 320×568 logical pixels.

## Activity insights

- A 600-seed interval oracle compares actual time by category and across all categories. Coverage includes overnight records, a clock-change day, distinct denominators for completion, deadlines, reschedules and skips, and aggregate-only export. [Insights tests](../test/insights_test.dart)
- Duration evidence uses confirmed completed tasks linked to logged activity. A large outlier leaves the median stable. The result includes its cohort, sample count, and observed range. [Duration learning](../lib/insights/duration_learning.dart)
- Large reports run on a worker isolate. The view reuses the result on resize and serializes fresh report requests.

The combined Health, Review, and Insights suite passed all 21 tests.

```sh
TZ=Europe/London flutter test --no-pub test/health_test.dart test/review_test.dart test/insights_test.dart
flutter analyze --no-pub lib/health lib/review lib/insights test/health_test.dart test/review_test.dart test/insights_test.dart
```

## Synthetic scale run

The AOT fixture generated 100,000 tasks, 50,000 activities, and 30,000 plans. It ran one warm-up and 11 measured report calculations with a fixed one-year span. Both profiles produced 365 recorded days, 85,714 confirmed completions, and 42,857 eligible duration samples.

| CPU affinity | Report median | Report maximum | Observation and estimate | RSS after the run |
|---|---:|---:|---:|---:|
| Host affinity with four-CPU quota | 252 ms | 658 ms | 107 ms | 125 MiB |
| One pinned CPU | 532 ms | 1,072 ms | 131 ms | 126 MiB |

These timings describe the pure AOT calculation on a shared host. The native UI and storage have separate profiles. [Scale fixture](../tool/benchmark/insights_scale.dart)

```sh
easy_insights_build=$(mktemp -d)
dart compile exe tool/benchmark/insights_scale.dart -o "$easy_insights_build/insights-scale"
TZ=Europe/London "$easy_insights_build/insights-scale"
TZ=Europe/London taskset -c 0 "$easy_insights_build/insights-scale"
```
