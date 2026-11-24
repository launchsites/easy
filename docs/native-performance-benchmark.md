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

## Calendar history index

The Calendar now indexes a snapshot once per event revision and caches up to 64 queried days. Its start-ordered maximum-end tree prunes history outside the requested window. Overnight and all-day spans retain exclusive end boundaries. Empty and reversed spans appear on their local start day. The focused tests also compare 180 dates and weekly windows against a full-history predicate, including a centuries-long event.

The Dart AOT microbenchmark reused exactly the 7,320 event records from the workspace fixture. Each sample queried the last 30 seeded dates and found 60 events. All 31 repetitions per method returned the same counts, and the ordered IDs matched the original scan on each date before timing.

| CPU affinity | Build p50 / p95 | Scan p50 / p95 | Uncached index p50 / p95 | Cached day p50 / p95 |
| --- | ---: | ---: | ---: | ---: |
| Four CPUs | 0.80 / 21.34 ms | 10.43 / 28.14 ms | 0.082 / 0.167 ms | 0.075 / 0.101 ms |
| One CPU | 0.76 / 24.73 ms | 6.82 / 34.01 ms | 0.083 / 0.095 ms | 0.077 / 0.142 ms |

The query columns are complete 30-query batches. The build column is one index rebuild. The fixture rows are already ordered by start, and the host was shared. [Four-CPU AOT results](benchmark-results/calendar-index-aot-four-cpu-20261124.json) · [One-CPU AOT results](benchmark-results/calendar-index-aot-one-cpu-20261124.json)

The native profile comparison used two frozen copies of the same app and fixture, with the Calendar indexing changes applied to the second copy. Each active 390×844 Calendar replay sent six alternating batches of 16 wheel inputs. Viewport setup completed before recording. UI and software raster p95 results were:

| Affinity | UI before | UI after | Software raster before | Software raster after |
| --- | ---: | ---: | ---: | ---: |
| Four CPUs | 17.17 ms | 18.86 ms | 38.60 ms | 30.63 ms |
| One CPU | 97.08 ms | 61.72 ms | 84.82 ms | 76.12 ms |

The one-CPU UI median increased from 21.49 to 26.45 ms. The four-CPU UI median moved from 2.58 to 2.50 ms. Both variants rendered the same visible Calendar records after the replay. These shared-host results show a lookup improvement and mixed frame timing. [Native scan profile](benchmark-results/calendar-index-native-before-epyc-20261124.json) · [Native indexed profile](benchmark-results/calendar-index-native-after-epyc-20261124.json)

To repeat the query benchmark, supply the legacy fixture generated by `native_ui_fixture.py`. Run the existing native trace driver with `--calendar-only` on each app variant to repeat the UI measurement.

```sh
dart compile exe tool/benchmark/calendar_index_bench.dart -o /tmp/easy-calendar-index
taskset -c 0 /tmp/easy-calendar-index "$easy_ui_dir/data/app.launchsites.easy/shared_preferences.json"
taskset -c 0,1,2,3 /tmp/easy-calendar-index "$easy_ui_dir/data/app.launchsites.easy/shared_preferences.json"
```

## Native offline navigation audit

The Linux release at `8670be647657925862931c2b3b58683656ca2ef7` opened an isolated synthetic workspace while a test-only seccomp filter denied IPv4 and IPv6 socket creation. A separate guard probe verified that both IP families failed with `EAFNOSUPPORT` and that a UNIX socket still opened. X11 and D-Bus used local UNIX sockets.

The one-CPU audit ran four cycles in 39.79 seconds, with 16 matching desktop checks and three successful mobile hold-and-drag switches to Calendar. The syscall trace recorded 77 network-related calls from the app and its descendants, including zero IPv4 or IPv6 calls. Read-only SQLite checks reported the same workspace digest and revision at both ends, with 7,320 events, 3,100 tasks and 1,301 notes. This verifies the observed default navigation and storage paths. [Raw offline audit](benchmark-results/native-offline-audit-epyc-20261124.json)

To repeat the guard on Linux x86-64, launch a built release bundle with an isolated X11 display and a disposable profile. Use the checked synthetic fixture and record only syscall counts in any published report.

```sh
cc -std=c17 -O2 -Wall -Wextra -Werror tool/benchmark/deny_ip_sockets.c -o /tmp/easy-deny-ip-sockets
strace -ff -qq -e trace=socket,connect,sendto,sendmsg,sendmmsg \
  -o "$easy_ui_dir/network.trace" /tmp/easy-deny-ip-sockets "$easy_bundle/easy"
```

## Sustained Linux navigation

The same frozen release completed 269 navigation cycles in 1,801 seconds on one virtual CPU. Each cycle switched desktop sections, issued scroll inputs and resized to one of five phone or tablet layouts. The sampled mobile hold-and-drag gesture opened Calendar 24 times out of 24. The original desktop probe found the expected heading in 127 of 156 samples. All 29 misses were on Today. A screenshot during a miss showed Today selected with the task list scrolled below the heading. Later observations record selected sidebar state independently of heading visibility.

The 11,721-record synthetic workspace had the same revision and digest at both ends and both SQLite integrity checks passed. Process RSS moved from 294 to 449 MiB and peak RSS was 487 MiB. Sampled RSS was 385 to 394 MiB in the middle and last third of the loop. These measurements describe this run, with software rendering on a shared host. [Original navigation soak](benchmark-results/native-soak-heading-probes-epyc-20261124.json)

On a disposable X11 display, launch the release with one permitted CPU and an isolated synthetic workspace. Run the probe in the same display after the window appears. It requires `xdotool`, ImageMagick and Tesseract.

```sh
python3 tool/benchmark/native_ui_soak.py \
  --seconds 1800 --minimum-cycles 100 --check-every 7 \
  --app-revision 8670be647657925862931c2b3b58683656ca2ef7 \
  --workspace-database "$easy_ui_dir/data/app.launchsites.easy/easy/workspace.sqlite3" \
  --output "$easy_ui_dir/native-soak.json"
```

## Large workspace startup and navigation baseline

Two fresh Linux release launches compared verified legacy workspace migrations under one virtual CPU. The standard fixture serialized 3.07 MB of data. The larger fixture serialized 21.37 MB and included 30,000 calendar events, 100,000 tasks and 3,001 notes. Both launches used isolated X11 displays. Sharing the host with other work adds timing variance.

| Fixture | Visible window | Verified Today | Calendar check | Tasks check | Notes check | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 11,721 records | 2.13 s | 8.58 s | 1.90 s | 0.69 s | 0.85 s | 404 MiB |
| 133,001 records | 1.93 s | 19.50 s | 17.45 s | 16.26 s | 7.75 s | 1,006 MiB |

The window column measures appearance of a blank or rendered window from process launch. The Today column adds the selected-route and OCR heading checks. Each navigation column measures a new click and its selected-route and heading checks. Both runs rendered the expected heading on all four routes and kept the same SQLite digest and revision between checks. A separate large-workspace observation found a verified database at 7.69 seconds and a blank shell at 18.32 seconds, with Today visible by 23.46 seconds. [Workspace scale baseline](benchmark-results/native-workspace-scale-before-epyc-20261124.json)

The scale probe creates two disposable profiles and isolated displays. It uses the frozen release palette to sample sidebar selection. It requires Xvfb, `xdotool`, ImageMagick and Tesseract.

```sh
dbus-run-session -- python3 tool/benchmark/native_workspace_scale.py \
  --binary "$easy_bundle/easy" \
  --app-revision 8670be647657925862931c2b3b58683656ca2ef7 \
  --today 2026-11-24 --output "$easy_ui_dir/workspace-scale.json"
```
