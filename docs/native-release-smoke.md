# Linux release smoke test

The Linux x64 release at `908c53adcbe53369c4cd11426dbec25367b0147c` passed all 29 visual checkpoints, with four process starts for the separate blank and sample workspace tests. The runner records the executable and Dart AOT checksums, screenshot checksums, and before-and-after SQLite revisions. The test took 174.74 seconds on a headless software-rendered X11 display. Its isolated profiles contain synthetic records. [Verification report](benchmark-results/native-release-smoke-908c53a-epyc-20261124.json)

- The desktop sidebar selected Today, Calendar, Tasks, and Notes. A keyboard-captured task was saved in SQLite and found through workspace search. The task and the original records survived reopening the app.
- Holding and dragging the mobile navigation button opened Calendar. Swiping the calendar changed the day. Gym history and the exercise progress chart opened at 390×844 and 320×568.
- Gym displayed the two synthetic body-weight records with Health notes enabled. Disabling Health notes removed the body-weight option after restart. Both measurements remained stored.
- The blank workspace stayed empty after Skip and restart. Choosing Full with samples in a separate profile saved six events, eight tasks, five notes, and one workout plan. Reopening kept the same revision and checksum in each profile.

The live workout check passed nine visual checkpoints in 76.81 seconds on `68fecf80a3c9da48e2d81252322efe4c0e19bbc2`. From the live Gym screen, one capture logged a stretch after the treadmill, updated the bench press to 60 kg × 8, 8, 6, and created a Work task. The explicit mark-done choice kept the three original targets of 50 kg × 8 and the treadmill settings. Two transactions saved the captured text and then the reviewed changes. The session refreshed in place and showed the same result after restarting. The SQLite workspace stayed at revision 3 with the same checksum after reopening. [Live capture report](benchmark-results/native-live-gym-68fecf8-epyc-20261124.json)

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
