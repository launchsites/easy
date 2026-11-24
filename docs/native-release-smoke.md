# Linux release smoke test

The Linux x64 release at `908c53adcbe53369c4cd11426dbec25367b0147c` passed all 29 visual checkpoints, with four process starts for the separate blank and sample workspace tests. The runner records the executable and Dart AOT checksums, screenshot checksums, and before-and-after SQLite revisions. The test took 174.74 seconds on a headless software-rendered X11 display. Its isolated profiles contain synthetic records. [Verification report](benchmark-results/native-release-smoke-908c53a-epyc-20261124.json)

- The desktop sidebar selected Today, Calendar, Tasks, and Notes. A keyboard-captured task was saved in SQLite and found through workspace search. The task and the original records survived reopening the app.
- Holding and dragging the mobile navigation button opened Calendar. Swiping the calendar changed the day. Gym history and the exercise progress chart opened at 390×844 and 320×568.
- Gym displayed the two synthetic body-weight records with Health notes enabled. Disabling Health notes removed the body-weight option after restart. Both measurements remained stored.
- The blank workspace stayed empty after Skip and restart. Choosing Full with samples in a separate profile saved six events, eight tasks, five notes, and one workout plan. Reopening kept the same revision and checksum in each profile.

The runner uses Flutter's Linux x64 release bundle, Python 3, Xvfb, xdotool, ImageMagick, and Tesseract. It checks simulated pointer and keyboard input at desktop and phone dimensions. Android, iOS, and physical touch use require separate checks.

```sh
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub
python3 tool/benchmark/native_release_smoke.py \
  --binary build/linux/x64/release/bundle/easy \
  --app-revision "$(git rev-parse HEAD)" \
  --output /tmp/easy-release-smoke-report.json \
  --health-scope --onboarding
```
