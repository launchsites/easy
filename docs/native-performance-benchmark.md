# Native scheduler and workspace performance

Measured on 24 November 2026 on a Debian 13 x86-64 virtual machine with AMD EPYC 9V74, five visible virtual CPUs, a four-CPU cgroup quota and a 16 GiB memory cap. Shared-host measurements include contention and scheduling noise.

## Scheduler

The Dart AOT runner timed only `proposeSchedule` on one permitted virtual CPU. Synthetic workloads use seed 20261124 with fragmented category availability, calendar commitments and buffers, deadlines, varying durations and prerequisites.

| Workload | Tasks | Commitments | Scheduled | Unscheduled | p50 | p95 | Max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Two-week mix | 160 | 28 | 109 | 41 | 0.96 ms | 2.10 ms | 2.22 ms |
| Crowded horizon | 1250 | 360 | 442 | 734 | 19.93 ms | 26.02 ms | 28.01 ms |
| Oversubscribed | 3000 | 540 | 683 | 2140 | 48.46 ms | 64.11 ms | 218.45 ms |

Each of the 31 timed repetitions returned the same schedule and unscheduled reasons as its verified baseline. The checks cover horizon and category availability, durations, split minimums, release times and deadlines, buffered commitments, dependencies, and overlaps. Completed tasks account for the difference between input tasks and decisions. Process peak RSS across all three workloads was 41.1 MiB. The two larger workloads exceeded the 16.67 ms frame budget at p95 on this host.

```sh
flutter pub get
dart compile exe tool/benchmark/scheduler_stress.dart -o /tmp/easy-scheduler-stress
taskset -c 4 /tmp/easy-scheduler-stress 31
```

Use any single permitted CPU on another host. Raw evidence contains every timed sample and the Dart version. [Scheduler timings](benchmark-results/scheduler-aot-epyc-20261124.json)

## Linux profile-mode workspace

The native Easy process used Flutter 3.50.1 profile mode in Xvfb with software OpenGL. Its synthetic legacy preference snapshot contains 7,320 calendar events across 3,660 days, 3,100 tasks and 1,301 notes. On the first open, an independent read of SQLite revision 1 confirmed all 11,721 records were present. The mixed sequence selected Today, Calendar, Tasks and Notes, sent wheel events, resized through 390, 320, 760 and 1280 logical pixels five times, then used the mobile orbit and scrolled the day timeline. Input and rendering ran in the real Linux window.

| Affinity | Span | Samples | p50 | p95 | Above 16.67 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Four CPUs | Flutter UI `Frame` | 201 | 2.62 ms | 86.32 ms | 31 |
| Four CPUs | `Rasterizer::DoDraw` | 201 | 21.48 ms | 64.28 ms | 126 |
| One CPU | Flutter UI `Frame` | 94 | 7.70 ms | 238.19 ms | 26 |
| One CPU | `Rasterizer::DoDraw` | 95 | 48.05 ms | 153.24 ms | 88 |

The one-CPU raster trace had one unmatched event at a trace boundary. Span counts differ between passes because the engine coalesces work and renders at its own pace. These are completed engine spans and a 60 Hz budget reference. Display cadence and dropped-frame counts require separate instrumentation. Process RSS after each replay was approximately 470 and 468 MiB. The same process reached about 553 MiB peak RSS across startup and both profiles.

Software GL raster times describe this headless Linux setup. Actual GPU, Android, iPhone and macOS timings require separate device runs. [Native UI timings](benchmark-results/native-ui-epyc-20261124.json)

A four-CPU diagnostic separated steady mobile Calendar scrolling from resize work. Four groups of 12 alternating wheel events produced UI p95 of 8.18 ms over 95 spans and raster p95 of 55.04 ms over 94 spans. Twenty Notes resizes through the four viewport sizes produced UI p95 of 169.22 ms and raster p95 of 62.97 ms over 77 spans each. The desktop Calendar wheel diagnostic produced only three timings, which gives too little evidence for a steady-scroll p95. [Native UI phase timings](benchmark-results/native-ui-phases-epyc-20261124.json)

After tracing, mobile Quick Capture committed a synthetic task on this same migrated workspace. An independent SQLite query confirmed revision 2 with exactly one added task, 7,320 events and 1,301 notes.

The Linux release build reopened that workspace, and desktop search returned the saved task. Previewing a day plan held SQLite revision 2. Selecting one result and confirming committed a single event at revision 3. The new event occupied the verified free window from 10:00 to 11:29 local time.

To reproduce on Linux, use a disposable X11 display with one visible Easy window, Python 3 with `websockets` 16.0, `taskset` and `xdotool`. Keep the machine log in a temporary directory because it contains the local VM Service access URI.

```sh
easy_ui_dir=$(mktemp -d)
python3 tool/benchmark/native_ui_fixture.py "$easy_ui_dir/data"
XDG_DATA_HOME="$easy_ui_dir/data" LIBGL_ALWAYS_SOFTWARE=1 \
  flutter run --profile -d linux --machine > "$easy_ui_dir/app.log" 2>&1
```

Once the desktop window has loaded, run the following from another shell on the same display. Substitute the temporary directory from the launch.

```sh
python3 tool/benchmark/native_ui_trace.py \
  --machine-log "$easy_ui_dir/app.log" \
  --output "$easy_ui_dir/native-ui-results.json"
```
