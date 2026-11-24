# Personal task evidence

The task context index provides local duration and recurring-task evidence for explicit review. It shares the elapsed-interval union used by Insights. Indexing cannot edit tasks, schedule blocks, start timers, or call a model. [Task context](../lib/task_context/task_context.dart)

## Inputs and results

- Supply canonical, visible tasks as `TaskContextTarget` values. Use the direct task ID for ordinary tasks and the occurrence ID with its explicit series ID for repeating tasks. Historical occurrences need their recorded completion instant. Supply only visible activity history from the same workspace.
- The index uses finished activity with positive closed spans and an exact task link. It merges overlapping spans and preserves gaps. Equivalent replay records count once and conflicting duplicates are excluded. A completed task contributes one duration sample when its linked elapsed time ends by the recorded completion. A linked timer for a task still in progress can show elapsed time in `exactElapsed` as a separate value.
- Evidence prefers the exact series within its category, then the same normalized title within that category, then the category. Case and spacing are normalized for title comparison. Category-only evidence has limited strength and carries no recurring attributes.
- The newest 32 matching outcomes describe the range, with the target itself excluded. The local model retains matching and used sample counts, oldest and newest completion dates, the median, both extremes and an outlier count when at least five samples are present. The range covers the observed minimum and maximum for smaller samples and the middle half otherwise. The strength labels account for recency, breadth and spread.
- Repeating evidence describes observed local start days and hours, gaps between distinct days, and how often separate logged segments occurred. It takes five distinct days and at least 70% concentration to flag a common weekday or hour. Pass the workspace clock to the index for the correct civil dates across calendar zone changes.

## Using the context

Cache the index by the workspace content and visibility revisions. Age and recency use the supplied `asOf` instant. Refresh the index for a new date when the caller displays age or uses recency decisions. Larger histories can be built away from the UI. Queries work on the retained evidence in memory.

`TaskDurationEvidence.optionalMetadata()` provides an aggregate with counts, elapsed ranges and relative ages. `compatibleMinutes` is a separate input for a provider that accepts a bounded list of whole-minute samples. Use the app’s explicit optional-metadata choice and applicable review flow before sending either representation to a configured provider. Resolve current task state before applying a reviewed duration. [Evidence models](../lib/task_context/task_context_models.dart)

## Validation

Eight focused tests cover closed and linked provenance, real versus planned time, exact elapsed union, repeated and conflicting imports, category isolation, the sample cap, stale evidence, and a local start series across the Europe/London autumn clock change. [Focused tests](../test/task_context_test.dart)

The synthetic Linux x64 AOT runs indexed 100,000 completed tasks and 100,000 linked activity records across 1,500 task groups. Each profile performed 1,000 measured queries after a warm-up and produced 32,000 sampled observations. The shared AMD EPYC 9V74 host has a four-CPU quota. The second profile pins the process to one CPU. RSS was measured after the run and includes the generated input records. [Scale fixture](../tool/benchmark/task_context_scale.dart)

| CPU affinity | Index build | Query p50 / p95 | RSS |
|---|---:|---:|---:|
| Default | 3,630 ms | 0.021 / 0.062 ms | 156 MiB |
| One pinned CPU | 4,428 ms | 0.024 / 0.060 ms | 157 MiB |

```sh
TZ=Europe/London flutter test --no-pub test/task_context_test.dart test/insights_test.dart
dart analyze lib/task_context test/task_context_test.dart tool/benchmark/task_context_scale.dart
easy_task_context_build=$(mktemp -d)
dart compile exe tool/benchmark/task_context_scale.dart -o "$easy_task_context_build/task-context-scale"
TZ=Europe/London "$easy_task_context_build/task-context-scale"
TZ=Europe/London taskset -c 0 "$easy_task_context_build/task-context-scale"
```
