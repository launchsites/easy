#!/usr/bin/env python3
"""Create a recurring Gym plan and edit a separate live custom metric offline."""

from argparse import ArgumentParser
from contextlib import ExitStack
from datetime import date
import json
import os
from pathlib import Path
from time import sleep, tzset

from local_inference import sha256
from native_persona_journey import Journey, private_display
from native_release_smoke import PHONE, click_at, initial_profile, new_profile, stored_workspace, workout_documents
from native_voice_capture import until
from native_workspace_scale import stop


INTERVAL = 'Amber intervals'
WEEKLY = 'Copper cadence'
EXERCISE = 'Tempo strides'
METRIC = 'Stride score'
WEEKDAYS = ('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')


def replace(journey, label, value, *, submit=False):
    journey.tap(label)
    sleep(0.14)
    journey.screen.send('key', 'ctrl+a')
    journey.text(value, submit=submit)


def saved_plan(database, name):
    state = stored_workspace(database)
    if state is None:
        return None
    records = workout_documents(database)['workout_plans']
    found = [item for item in records if item['name'] == name]
    if found:
        if len(found) != 1 or state['quick_check'] != 'ok':
            raise RuntimeError('The planned workout was not unique or the database became unhealthy.')
        return state, found[0]
    return None


def first_metric(exercise):
    items = exercise.get('metrics', [])
    if len(items) != 1:
        raise RuntimeError('Expected one custom exercise metric.')
    return items[0]


def active_session(database, plan_id):
    state = stored_workspace(database)
    if state is None:
        return None
    session = workout_documents(database)['gym_sessions'][-1]
    if session.get('planId') == plan_id and session.get('finishedAt') is None:
        return state, session
    return None


def run(args, report):
    root = args.output
    env = {**os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
           'GSETTINGS_BACKEND': 'memory', 'OMP_THREAD_LIMIT': '1', 'TZ': 'UTC'}
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    env, profile = new_profile(root/'profile', env)
    initial_profile(profile)
    os.chdir(root)
    db = profile/'easy'/'workspace.sqlite3'
    today = date.today()
    next_day_of_week = today.isoweekday() % 7 + 1
    with ExitStack() as stack:
        private_display(args, root, env, stack)
        journey = Journey(args, root, env, stack, report)
        app = journey.open('home')
        screen = journey.screen
        before = until(lambda: stored_workspace(db), 'the first workspace revision')
        journey.mode('Gym')
        journey.tap('Plans')
        journey.check('empty-plans', 'No workout plans')

        def new_plan(name):
            click_at(screen, 190, 812)
            journey.check(f'{name}-editor', 'Workout name')
            sleep(0.5)
            replace(journey, 'Workout name', name)

        new_plan(INTERVAL)
        journey.tap('Every N days')
        journey.check('interval-choice', 'Repeat every')
        replace(journey, 'Repeat every', '3')
        journey.tap('Add exercise')
        journey.check('exercise-editor', 'Exercise name')
        sleep(0.5)
        replace(journey, 'Exercise name', EXERCISE)
        journey.tap('Cardio')
        journey.check('cardio-fields', 'Distance')
        replace(journey, 'Distance', '0.6')
        replace(journey, 'Incline', '2')
        replace(journey, 'Minutes', '6')
        journey.tap('Add exercise metric')
        journey.check('custom-metric-dialog', 'Add metric')
        sleep(0.45)
        replace(journey, 'Label', METRIC)
        replace(journey, 'Unit', 'points')
        replace(journey, 'Value', '7', submit=True)
        journey.check('custom-metric-draft', METRIC)
        sleep(0.45)
        click_at(screen, 190, 812)
        journey.check('plan-with-cardio', EXERCISE)
        if stored_workspace(db) != before:
            raise RuntimeError('The workout plan draft caused a partial saved revision.')
        sleep(0.5)
        click_at(screen, 190, 812)
        journey.check('stored-interval-plan', 'Every 3 days')
        state, interval = until(lambda: saved_plan(db, INTERVAL), 'the interval plan in SQLite')
        if state['revision'] != before['revision'] + 1:
            raise RuntimeError('Creating one interval plan used more than one revision.')
        schedule = interval['schedule']
        if schedule != {'kind': 'interval', 'startDate': today.isoformat(),
                        'weekdays': [], 'intervalDays': 3} or len(interval['exercises']) != 1:
            raise RuntimeError('The saved plan did not keep the selected anchored interval.')
        cardio = interval['exercises'][0]
        metric = first_metric(cardio)
        if (cardio['name'], cardio['kind'], cardio['distanceKm'], cardio['inclinePercent'], cardio['minutes'],
                metric['label'], metric['unit'], metric['value']) != (
                EXERCISE, 'cardio', 0.6, 2, 6, METRIC, 'points', 7):
            raise RuntimeError('The saved cardio and custom metric differ from the reviewed plan.')

        new_plan(WEEKLY)
        journey.tap('Weekdays')
        journey.check('weekly-selector', WEEKDAYS[next_day_of_week-1])
        journey.tap(WEEKDAYS[next_day_of_week-1])
        click_at(screen, 190, 812)
        journey.check('stored-weekly-plan', WEEKLY)
        state, weekly = until(lambda: saved_plan(db, WEEKLY), 'the weekly plan in SQLite')
        expected_weekdays = sorted((today.isoweekday(), next_day_of_week))
        if (weekly['schedule'] != {'kind': 'weekdays', 'startDate': today.isoformat(),
                                   'weekdays': expected_weekdays, 'intervalDays': 1} or
                state['revision'] != before['revision'] + 2):
            raise RuntimeError('Weekly changes did not keep the selected days or expected revision.')

        app.kill()
        app.wait(timeout=8)
        app = journey.open('reopened-home')
        screen = journey.screen
        if saved_plan(db, WEEKLY) != (state, weekly) or saved_plan(db, INTERVAL)[1] != interval:
            raise RuntimeError('Plan templates changed during process restarts.')
        journey.mode('Gym')
        journey.check('reopened-next-workout', INTERVAL)
        _, exercise_y = journey.check('reopened-preview', EXERCISE)
        sleep(0.45)
        click_at(screen, 105, exercise_y + 48)
        journey.check('started-interval-session', 'Finish')
        saved, live = until(lambda: active_session(db, interval['id']), 'the started workout')
        if (saved['revision'] != state['revision'] + 1 or
                live['exercises'] != interval['exercises'] or live['plannedExercises'] != interval['exercises']):
            raise RuntimeError('Opening the planned session changed the template or copied a wrong target.')
        journey.tap(METRIC)
        journey.check('metric-editing', f'{METRIC} {EXERCISE}')
        sleep(0.35)
        click_at(screen, 100, 805)
        screen.send('key', 'ctrl+a')
        journey.text('6.5', submit=True)
        journey.check('actual-value-visible', '6.5')

        def edited_metric():
            current = active_session(db, interval['id'])
            return current if current and first_metric(current[1]['exercises'][0])['value'] == 6.5 else None

        edited, session = until(edited_metric, 'one actual metric revision')
        if (edited['revision'] != saved['revision'] + 1 or
            session['plannedExercises'] != interval['exercises'] or
            saved_plan(db, INTERVAL)[1] != interval or
            first_metric(session['exercises'][0])['id'] != metric['id']):
            raise RuntimeError('The actual metric edit leaked to its template or changed its stable ID.')
        stop(app)
        app = journey.open('final-home')
        journey.mode('Gym')
        journey.check('final-resumable-workout', INTERVAL)
        _, exercise_y = journey.check('final-workout-preview', EXERCISE)
        sleep(0.45)
        click_at(journey.screen, 105, exercise_y + 48)
        journey.check('final-live', 'Finish')
        journey.check('actual-value-reopened', '6.5')
        if edited_metric() != (edited, session):
            raise RuntimeError('The actual result changed after reopening.')
        report.update(status='passed', workspace_revision=edited['revision'], weekday_count=len(expected_weekdays),
                      interval_days=3, planned_metric=7, actual_metric=6.5)
        stop(app)


def main():
    p = ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--app-revision', required=True)
    p.add_argument('--deny-ip', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--xvfb', default='Xvfb')
    p.add_argument('--xdotool', default='xdotool')
    p.add_argument('--display', type=int, default=193)
    p.add_argument('--x11-capture', default='import')
    p.add_argument('--tesseract', default='tesseract')
    p.add_argument('--timeout', type=int, default=50)
    args = p.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.deny_ip = args.deny_ip.resolve(strict=True)
    args.output = args.output.resolve(strict=True)
    os.environ['TZ'] = 'UTC'
    tzset()
    report = {'status': 'failed', 'app_revision': args.app_revision, 'ip_sockets_blocked': True,
              'aot_sha256': sha256(args.binary.parent/'lib/libapp.so'),
              'executable_sha256': sha256(args.binary), 'checks': {}}
    try:
        run(args, report)
    except Exception as error:
        report['error'] = str(error)
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
