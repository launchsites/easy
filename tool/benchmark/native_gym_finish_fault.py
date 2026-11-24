#!/usr/bin/env python3
"""Check native workout completion when the SQLite WAL cannot grow."""

from argparse import ArgumentParser
from contextlib import ExitStack, closing
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import resource
import shutil
import sqlite3
from time import sleep, tzset

from local_inference import sha256
from native_persona_journey import Journey, private_display
from native_release_smoke import (LIVE_WORKOUT, PHONE, click_at, get_window, initial_profile,
                                  new_profile, resize, stored_workspace, workout_documents)
from native_voice_capture import Screen, start_child, until, words
from native_workspace_scale import stop


DRAFT = 'Keep this draft'
FOLLOW_UP = 'Review the next training session'
RULE = 'workout-follow-up'


def fixture(profile):
    initial_profile(profile, live_workout=True)
    pref = profile/'shared_preferences.json'
    raw = json.loads(pref.read_text())
    data = json.loads(raw['easy.workspace.v1'])
    for event in data['events']:
        for boundary in ('start', 'end'):
            event[boundary] = datetime.fromisoformat(event[boundary]).isoformat(timespec='milliseconds')
        event['location'] = None
    for task in data['tasks']:
        task['date'] = datetime.fromisoformat(task['date']).isoformat(timespec='milliseconds')
    for note in data['notes']:
        note['updated'] = datetime.fromisoformat(note['updated']).isoformat(timespec='milliseconds')
        if not note.get('noteToSelf'):
            note.pop('noteToSelf', None)
    enabled = (datetime.now(timezone.utc) - timedelta(minutes=15)).isoformat()
    data['automationRules'] = {
        'version': 1, 'enabledSince': enabled, 'drafts': [], 'receipts': [],
        'rules': [{'id': RULE, 'name': 'Plan next session', 'trigger': 'workoutFinished',
                   'enabledSince': enabled, 'condition': {'category': 'gym', 'weekdays': []},
                   'action': {'kind': 'taskDraft', 'text': FOLLOW_UP, 'category': 'gym'}}],
    }
    raw['easy.workspace.v1'] = json.dumps(data)
    sessions = raw['easy.gym-sessions.v1']
    active = json.loads(sessions[-1])
    active['progress'] = {json.dumps(['treadmill'], separators=(',', ':')): 'done'}
    sessions[-1] = json.dumps(active)
    pref.write_text(json.dumps(raw))


def all_data(database):
    workspace = stored_workspace(database)
    if workspace is None:
        return None
    sessions = workout_documents(database)['gym_sessions']
    if not sessions or sessions[-1].get('planId') != 'live-fixture':
        raise RuntimeError('The planned session fixture was not present.')
    return workspace, sessions


def isolated_launch(journey, label):
    args = journey.args
    app = start_child(journey.stack, journey.env, journey.root/f'{label}.log', 'bash', '-c',
                      "trap '' XFSZ\nexec \"$@\"", 'easy-workout-fault', args.deny_ip, args.binary)
    window = until(lambda: get_window(args, journey.env, app), 'the disposable app window', args.timeout)
    journey.screen = Screen(args, journey.root, journey.env, window)
    journey.screen.send('windowfocus', window)
    resize(journey.screen, PHONE)
    journey.check(label, 'Note to self')
    return app


def dialog_finish(screen):
    for layout in (11, 6):
        points = []
        for line in screen.labels(layout, capture=layout == 11):
            for row in line:
                x = int(row['left']) + int(row['width']) // 2
                y = int(row['top']) + int(row['height']) // 2
                if words(row['text']) == ['finish'] and x > PHONE[0] // 2 and y > PHONE[1] // 3:
                    points.append((x, y))
        if points:
            return max(points, key=lambda point: point[1])
    return None


def submit_finish(journey, label):
    click_at(journey.screen, PHONE[0] - 46, 28)
    journey.check(label, 'Discard draft')
    sleep(0.35)
    point = until(lambda: dialog_finish(journey.screen), 'the explicit finish confirmation')
    click_at(journey.screen, *point)


def expect_finished(before, after):
    prior, prior_sessions = before
    saved, saved_sessions = after
    active = dict(saved_sessions[-1])
    finished = active.get('finishedAt')
    active['finishedAt'] = None
    if (not finished or prior_sessions[-1] != active or prior_sessions[:-1] != saved_sessions[:-1] or
            saved['revision'] != prior['revision'] + 1 or saved['quick_check'] != 'ok'):
        raise RuntimeError('Finish failed to preserve the original session and commit exactly once.')
    document = dict(saved['document'])
    automation = document.pop('automationRules')
    before_document = {key: value for key, value in prior['document'].items() if key != 'automationRules'}
    if document != before_document:
        raise RuntimeError('Finishing the workout changed unrelated records.')
    drafts = automation['drafts']
    if (len(drafts) != 1 or len(automation['receipts']) != 1 or drafts[0]['ruleId'] != RULE or
            drafts[0]['action']['text'] != FOLLOW_UP or drafts[0]['status'] != 'pending' or
            drafts[0]['event']['trigger'] != 'workoutFinished' or
            datetime.fromisoformat(drafts[0]['event']['occurredAt']).replace(tzinfo=timezone.utc) !=
            datetime.fromisoformat(finished).replace(tzinfo=timezone.utc)):
        raise RuntimeError('The reviewed follow-up draft did not share the workout finish write.')


def run(args, report):
    root = args.output
    env = {**os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
           'GSETTINGS_BACKEND': 'memory', 'OMP_THREAD_LIMIT': '1', 'TZ': 'UTC'}
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    env, profile = new_profile(root/'profile', env)
    fixture(profile)
    os.chdir(root)
    database = profile/'easy'/'workspace.sqlite3'
    wal = database.with_name(database.name + '-wal')
    with ExitStack() as stack:
        private_display(args, root, env, stack)
        journey = Journey(args, root, env, stack, report)
        app = isolated_launch(journey, 'home')
        journey.gym('gym')
        first_set = json.dumps(['bench', 'first'], separators=(',', ':'))

        def logged_first_set():
            saved = all_data(database)
            return saved if saved and saved[1][-1]['progress'].get(first_set) == 'done' else None

        sleep(0.45)
        click_at(journey.screen, 298, 280)
        before = until(logged_first_set, 'a marked bench set in SQLite')
        click_at(journey.screen, 110, 806)
        journey.text(DRAFT)
        journey.check('typed-draft', DRAFT)
        if (before[0]['quick_check'] != 'ok' or before[1][-1].get('finishedAt') or
                before[0]['document']['automationRules']['drafts']):
            raise RuntimeError('The fixture opened with an unexpected finished workout or pending draft.')

        click_at(journey.screen, PHONE[0] - 46, 28)
        journey.check('cancel-prompt', 'Discard draft')
        journey.tap('Keep logging')
        until(lambda: not journey.screen.find('Keep logging'), 'the confirmation dialog to close')
        journey.check('cancel-retained-draft', DRAFT)
        if all_data(database) != before:
            raise RuntimeError('Cancel changed the saved workout.')
        limits = resource.prlimit(app.pid, resource.RLIMIT_FSIZE)
        with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as reader:
            reader.execute('BEGIN')
            reader.execute('SELECT revision FROM revisions ORDER BY revision DESC LIMIT 1').fetchone()
            ceiling = wal.stat().st_size
            if not 0 < ceiling < 2 * 1024 * 1024:
                raise RuntimeError('The fixture WAL size is outside its expected bounds.')
            resource.prlimit(app.pid, resource.RLIMIT_FSIZE, (ceiling, limits[1]))
            try:
                submit_finish(journey, 'fault-prompt')
                def reported_failure():
                    if journey.screen.find('Session complete'):
                        shutil.copyfile(journey.screen.path, root/'premature-summary.png')
                        if all_data(database) != before or wal.stat().st_size != ceiling:
                            raise RuntimeError('A summary appeared while the limited workspace had changed.')
                        report.update(premature_summary_with_failed_write=True,
                                      failed_write_kept_revision=before[0]['revision'],
                                      file_size_ceiling_bytes=ceiling)
                        raise RuntimeError('The app showed a completion summary for a failed write.')
                    return journey.screen.find('workout could not be saved')

                until(reported_failure, 'the native workout save failure', args.timeout)
                journey.check('fault-acknowledged', 'workout could not be saved')
                journey.check('fault-retained-draft', DRAFT)
                if journey.screen.find('Session complete'):
                    raise RuntimeError('The app showed a completion summary for a failed write.')
                if all_data(database) != before or wal.stat().st_size != ceiling:
                    raise RuntimeError('The failed workout changed the SQLite revision or WAL size.')
            finally:
                if app.poll() is None:
                    resource.prlimit(app.pid, resource.RLIMIT_FSIZE, limits)

        submit_finish(journey, 'retry-prompt')
        journey.check('retry-finished', 'Session complete')
        saved = all_data(database)
        expect_finished(before, saved)
        app.kill()
        app.wait(timeout=8)
        app = isolated_launch(journey, 'reopened-home')
        journey.mode('Gym')
        journey.check('reopened-gym', 'History')
        journey.tap('History')
        journey.check('reopened-history', 'Workout history')
        journey.check('reopened-finished-workout', LIVE_WORKOUT)
        if saved != all_data(database):
            raise RuntimeError('The exact final session or follow-up changed on restart.')
        stop(app)
        report.update(status='passed', failed_write_kept_revision=before[0]['revision'],
                      retry_and_restart_revision=saved[0]['revision'], stable_digest=saved[0]['digest'],
                      pending_workout_follow_up_count=1, file_size_ceiling_bytes=ceiling)


def main():
    p = ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--app-revision', required=True)
    p.add_argument('--deny-ip', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--xvfb', default='Xvfb')
    p.add_argument('--xdotool', default='xdotool')
    p.add_argument('--display', type=int, default=192)
    p.add_argument('--x11-capture', default='import')
    p.add_argument('--tesseract', default='tesseract')
    p.add_argument('--timeout', type=int, default=45)
    args = p.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.deny_ip = args.deny_ip.resolve(strict=True)
    args.output = args.output.resolve(strict=True)
    os.environ['TZ'] = 'UTC'
    tzset()
    report = {'status': 'failed', 'app_revision': args.app_revision,
              'ip_sockets_blocked': True, 'aot_sha256': sha256(args.binary.parent/'lib/libapp.so'),
              'executable_sha256': sha256(args.binary), 'checks': {}}
    try:
        run(args, report)
    except Exception as error:
        report['error'] = str(error)
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
