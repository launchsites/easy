# Scheduling performance

The deterministic planner keeps occupied time ranges sorted and merges adjacent ranges in place. It searches from the first relevant range and stops when it finds the first feasible uninterrupted block. Split placement keeps the existing chronological and largest-gap rules. Failed searches with the same category, horizon, effort, and split minimum can be reused until the next placement changes occupancy.

## Single-CPU measurements

Each trial ran in a fresh Linux Dart AOT process pinned to one logical CPU on an AMD EPYC 9V74 host. The stopwatch covers the planner after construction of the synthetic fixture. The table reports the median of five alternating baseline and optimized trials. Each trial produced identical placement counts and fingerprints for its profile.

| Profile | Tasks | Commitments | Placed | Baseline | Optimized |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary week | 850 | 175 | 117 | 10 ms | 2 ms |
| Open month | 15,000 | 0 | 967 | 78 ms | 18 ms |
| Packed 21-day calendar | 18,000 | 3,780 | 12,600 | 5,009 ms | 77 ms |
| Fragmented month | 18,000 | 5,580 | 124 | 5,709 ms | 21 ms |

Peak process RSS in the packed profile ranged from 50.6–50.9 MiB with the baseline and 45.4–45.6 MiB after optimization. Other workloads on the host varied during the run. Calendar reads, workspace decoding and rendering have separate performance measurements. [Raw measurements](benchmark-results/scheduling-single-cpu-20261124.json)

## Validation

Twelve thousand seeded differential cases matched decision order, exact serialized block times, reasons and prerequisite results against the previous planner. They covered 110,769 decisions, including mixed local and UTC times, fractional minutes, scoped hours, buffers, deadlines, dependencies, and missing fields. A frozen source run passed all 40 scheduling tests, including the 2,500-case exact split oracle, 5,000 scheduling invariant cases, and the 20,000-node cycle check.

```sh
dart compile exe tool/benchmark/scheduling_scale.dart -o /tmp/easy-scheduling-benchmark
taskset -c 0 /tmp/easy-scheduling-benchmark packed
```

The runner also accepts `ordinary`, `wide`, and `blocked`. Use a CPU number available to the process. [Fixture runner](../tool/benchmark/scheduling_scale.dart)

## Automatic estimate candidate ordering

The automatic estimate pass filters completed tasks, existing estimates, scheduling holds, recurring base tasks, and titles over the request limit before sorting. Large workspace snapshots are scanned and sorted in slices of up to 1,024 tasks, then merged in slices of up to 4,096 results. The pass gives the event loop a turn and checks cancellation between slices. All measured profiles matched the previous candidate order using due or scheduled instant, priority, and ID.

These medians cover 12 Dart AOT trials for each 120,000-task fixture on one logical AMD EPYC 9V74 CPU. The worker measurements use `Isolate.run` and the same complete task snapshot. The synchronous and cooperative columns include the full ranked result.

| Input | Eligible | Previous sort and first candidate | Synchronous rank | Cooperative rank | Worker submission | Cooperative event gap p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| All eligible | 120,000 | 156.0 ms | 174.2 ms | 243.3 ms | 126.3 ms | 1.138 ms |
| Mixed history | 6,000 | 8.2 ms | 4.4 ms | 10.0 ms | 96.5 ms | 0.100 ms |
| Mostly held, recurring, or oversize | 4,800 | 122.7 ms | 5.2 ms | 9.7 ms | 107.5 ms | 0.079 ms |

At 2,048 fully eligible tasks, synchronous ranking took 0.702 ms at the median and 0.868 ms at p95. The timer probe measures wall time between observed event-loop turns, including shared-host scheduling and garbage collection. It recorded a 292 ms maximum gap in the large all-eligible profile during concurrent builds and UI tests. The measurements cover ranking in a standalone process. [Raw measurements](benchmark-results/automatic-estimate-order-epyc-20261124.json)

```sh
dart compile exe tool/benchmark/automatic_estimate_order_bench.dart -o /tmp/easy-estimate-order-benchmark
taskset -c 4 /tmp/easy-estimate-order-benchmark 120000
taskset -c 4 /tmp/easy-estimate-order-benchmark 2048
```
