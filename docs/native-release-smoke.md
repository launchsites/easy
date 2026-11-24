# Linux release smoke test

The Linux x64 release at `908c53adcbe53369c4cd11426dbec25367b0147c` passed all 29 visual checkpoints, with four process starts for the separate blank and sample workspace tests. The runner records the executable and Dart AOT checksums, screenshot checksums, and before-and-after SQLite revisions. The test took 174.74 seconds on a headless software-rendered X11 display. Its isolated profiles contain synthetic records. [Verification report](benchmark-results/native-release-smoke-908c53a-epyc-20261124.json)

- The desktop sidebar selected Today, Calendar, Tasks, and Notes. A keyboard-captured task was saved in SQLite and found through workspace search. The task and the original records survived reopening the app.
- Holding and dragging the mobile navigation button opened Calendar. Swiping the calendar changed the day. Gym history and the exercise progress chart opened at 390×844 and 320×568.
- Gym displayed the two synthetic body-weight records with Health notes enabled. Disabling Health notes removed the body-weight option after restart. Both measurements remained stored.
- The blank workspace stayed empty after Skip and restart. Choosing Full with samples in a separate profile saved six events, eight tasks, five notes, and one workout plan. Reopening kept the same revision and checksum in each profile.

The live workout check passed nine visual checkpoints in 76.81 seconds on `68fecf80a3c9da48e2d81252322efe4c0e19bbc2`. From the live Gym screen, one capture logged a stretch after the treadmill, updated the bench press to 60 kg × 8, 8, 6, and created a Work task. The explicit mark-done choice kept the three original targets of 50 kg × 8 and the treadmill settings. Two transactions saved the captured text and then the reviewed changes. The session refreshed in place and showed the same result after restarting. The SQLite workspace stayed at revision 3 with the same checksum after reopening. [Live capture report](benchmark-results/native-live-gym-68fecf8-epyc-20261124.json)

An extracted 64-bit review archive from `12730c86ac311e5c473a6810a69cc31ec257f1ff` passed all 38 baseline checkpoints in 223.43 seconds. [Release archive verification](benchmark-results/native-release-smoke-12730c8-epyc-20261124.json)

The extracted review archive from `6f18fe901e9c3b2622240ff8b17e26d626b0df3e` passed the same 38 checkpoints in 222.81 seconds. [Updated archive verification](benchmark-results/native-release-smoke-6f18fe9-epyc-20261124.json)

The runner uses Flutter's Linux x64 release bundle, Python 3, Xvfb, xdotool, ImageMagick, and Tesseract. It checks simulated pointer and keyboard input at desktop and phone dimensions. Android, iOS, and physical touch use require separate checks.

```sh
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub
python3 tool/benchmark/native_release_smoke.py \
  --binary build/linux/x64/release/bundle/easy \
  --app-revision "$(git rev-parse HEAD)" \
  --output /tmp/easy-release-smoke-report.json \
  --health-scope --onboarding --live-gym-capture
```

## Large workout screens

A Flutter widget probe on one logical CPU opened a synthetic 1,200-exercise workout with six sets per exercise, then marked its first set done. The eager list read all 1,200 exercise names on each action. The lazy list read two. Across three warm runs, the median dropped from 757 to 377 ms when opening and from 647 to 349 ms when marking the set. These intervals include the widget test harness and rendering. [Raw measurements](benchmark-results/workout-viewport-build-epyc-20261124.json)

The regression checks verify that a reordered exercise keeps its set progress and original targets while the list builds nearby cards. Portrait and landscape at 200% text scale tested the capture control and scroll path. The same focused run exercised live, cross-Focus capture and session persistence.

A separate Linux AOT replay alternated the baseline and candidate across six fresh profiles on one logical CPU. Each run opened the 1,200-exercise workout and checked or cleared the first set six times. All 36 actions produced exactly one SQLite revision each, with the original target intact. The median time to the first workout frame was 1,819 ms before the list change and 751 ms with it. The median of the warm per-launch save timings moved from 642 to 261 ms. Other work shared the core during the replay, and the individual save timings varied. [Native measurements](benchmark-results/native-gym-scale-epyc-20261124.json)

The native comparison used `68fecf8` as the baseline and the same revision with `lib/gym_session.dart` from `29c841a` as the candidate. Build each snapshot with `flutter build linux --release`, then pass the two executables to the runner.

```sh
python3 tool/benchmark/native_gym_scale.py \
  --baseline /tmp/easy-baseline/bundle/easy \
  --candidate /tmp/easy-candidate/bundle/easy \
  --output /tmp/easy-native-gym-scale
```

## Offline food photo import

The Linux x64 release at `d1ac727b57f3362cadc16e735db17ca9f5e3dfff` used GTK's native file chooser to attach a synthetic PNG to a meal at 390×844. IPv4 and IPv6 were blocked and the workspace had no AI provider configured. Easy showed the imported pixels, kept the photo draft in revision 2, and saved the meal with a measured 150 g portion in revision 3. After deleting the original fixture and restarting, the managed PNG had the same SHA-256, the photo opened again, and the workspace retained the same SQLite digest. The fixture used file import and manual nutrition entry. [Verification report](benchmark-results/native-meal-photo-d1ac727-epyc-20261124.json)

To repeat the offline check, compile the socket blocker and use it to launch the release in a disposable profile. Choose Full at setup. In Health, open Meal log, attach a local test PNG, add a measured food portion, and save. Remove the fixture from its original location and reopen the saved photo after restarting with the same profile.

```sh
cc -std=c17 -O2 -Wall -Wextra -Werror tool/benchmark/deny_ip_sockets.c -o /tmp/easy-deny-ip-sockets
easy_check_dir=$(mktemp -d)
XDG_DATA_HOME="$easy_check_dir/data" XDG_CONFIG_HOME="$easy_check_dir/config" \
  XDG_CACHE_HOME="$easy_check_dir/cache" \
  /tmp/easy-deny-ip-sockets "$(pwd)/build/linux/x64/release/bundle/easy"
```

## Offline calendar transfer

The same Linux release opened a synthetic `.ics` file through GTK at 390×844 while IPv4 and IPv6 were blocked. The preview showed three daily occurrences and a separate event. Unchecking that event and confirming created one imported calendar in one SQLite revision. The preview alone left the workspace unchanged. The stored calendar and the GTK export kept the recurrence rule and next-day override, and the export matched the stored document byte for byte.

After removing the original file and restarting, Today showed the first occurrence. Swiping through Calendar showed the override on day two and the original series title on day three. The workspace digest stayed the same. To repeat the check with the offline launcher above, open Settings, Calendar files, and Import or export events. Choose a test calendar with a short recurring series and a standalone event, clear the standalone event, and import. Open the imported calendar under Calendar files to export it. [Verification report](benchmark-results/native-calendar-transfer-d1ac727-epyc-20261124.json)

## A day across Focus modes

The extracted `12730c8` archive passed 37 visual checkpoints in one compact, offline profile. Today showed the note, upcoming events, and due tasks. The navigation hold opened Calendar. The three-step event input rejected an end equal to the start without saving and committed one 14:00–14:45 appointment for the next day. During the Gym workout, one reviewed capture kept the original targets, logged a stretch and the completed sets, and saved a Work task. Health opened from Gym and saved a fixture photo and a measured 150 g portion. After a forced process exit and removal of the original photo, the Work task, swiped calendar appointment, active workout, and managed photo reopened. SQLite stayed at revision 6 with the same document checksum. [Journey report](benchmark-results/native-persona-journey-12730c8-epyc-20261124.json)

A second run verified the inline Fits now marker on Today at 390×844 and 1440×900. The eligible Work task was suggested when the calendar was free. Completing it saved one revision and removed the marker. In a separate profile with a conflicting Personal calendar appointment, the Work task remained visible without an inline recommendation. The app still offered the general What fits now action in that profile. [Availability report](benchmark-results/native-today-fit-12730c8-epyc-20261124.json)

Use the same socket blocker with Xvfb, xauth, xdotool, ImageMagick, Tesseract, and Pillow installed. Each run takes a fresh output directory and an unused X11 display number. The report and synthetic screenshots are written inside that directory.

```sh
for scenario in persona_journey today_fit; do
  python3 "tool/benchmark/native_${scenario}.py" \
    --binary build/linux/x64/release/bundle/easy \
    --app-revision "$(git rev-parse HEAD)" \
    --deny-ip /tmp/easy-deny-ip-sockets --output "$(mktemp -d)"
done
```

## Workout completion after a write failure

The native workout test used an isolated workspace with a planned workout and one follow-up draft rule. With a 65,952-byte process limit on the SQLite write-ahead log, the earlier `12730c8` build showed a completed-session summary while SQLite still held revision 2. The `6f18fe9` build showed the save failure, retained the unsaved text, and kept the same revision and set results. [Earlier result](benchmark-results/native-gym-finish-before-12730c8-20261124.json) · [Updated result](benchmark-results/native-gym-finish-6f18fe9-20261124.json)

After releasing the limit, a confirmed retry finished the workout and created one pending follow-up draft in a single revision. The original set results and other records were intact. The finished workout was visible in History after a forced process exit, and the reopened workspace still held the same revision and pending draft. The 15-screen check ran with IPv4 and IPv6 sockets blocked.

```sh
python3 tool/benchmark/native_gym_finish_fault.py \
  --binary build/linux/x64/release/bundle/easy \
  --app-revision "$(git rev-parse HEAD)" \
  --deny-ip /tmp/easy-deny-ip-sockets --output "$(mktemp -d)"
```

## Planned workouts and custom metrics

The extracted `6f18fe9` release passed 24 offline checkpoints at 390×844. It saved an anchored three-day interval plan and a separate two-weekday plan. Each plan committed once, and the unfinished plan editor left the stored workspace unchanged. After a forced process exit, Gym opened the due interval workout. Its cardio targets were 0.6 km, 2% incline, and six minutes. Editing the custom Stride score from 7 points to 6.5 changed one live-session revision. The planned value, saved template and metric identifier stayed intact. The live screen showed both values after reopening. [Workout plan report](benchmark-results/native-workout-plan-6f18fe9-20261124.json)

```sh
python3 tool/benchmark/native_workout_plan.py \
  --binary build/linux/x64/release/bundle/easy \
  --app-revision "$(git rev-parse HEAD)" \
  --deny-ip /tmp/easy-deny-ip-sockets --output "$(mktemp -d)"
```
