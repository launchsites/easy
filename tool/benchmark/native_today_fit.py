#!/usr/bin/env python3
"""Check the Today task fit against a confirmed free and occupied calendar."""

from argparse import ArgumentParser
from contextlib import ExitStack
from datetime import datetime, timedelta
import json
import os
import shutil
from pathlib import Path
from time import sleep, tzset

from local_inference import sha256
from native_release_smoke import new_profile, stored_workspace, resize
from native_voice_capture import until, words
from native_workspace_scale import stop
from native_persona_journey import Journey, private_display


def scene(profile, *, occupied):
    profile.mkdir()
    now = datetime.now()
    today = now.date()
    task = {'id': 'short-work', 'title': 'Send the studio notes', 'category': 'work',
            'date': today.isoformat(), 'estimatedMinutes': 15, 'done': False}
    settings = {'availability': [{'id': 'working-time', 'weekdays': [today.isoweekday()],
                                 'startMinute': 0, 'endMinute': 1440, 'categories': ['work']}]}
    events = [] if not occupied else [{'id': 'personal-event', 'title': 'Dentist appointment',
        'category': 'personal', 'allDay': False,
        'start': (now - timedelta(minutes=5)).isoformat(),
        'end': (now + timedelta(minutes=55)).isoformat()}]
    note = {'id': 'today-note', 'title': 'Bring a jacket', 'body': 'The synthetic note for today.',
            'noteToSelf': True, 'updated': now.isoformat()}
    document = {'events': events, 'tasks': [task], 'notes': [note], 'schedulingSettings': settings}
    (profile/'shared_preferences.json').write_text(json.dumps({'easy.workspace.v1': json.dumps(document)}))


def fit_badge(screen):
    for layout in (11, 6):
        for line in screen.labels(layout, capture=layout == 11):
            parts = [part for row in line for part in words(row['text'])]
            for index in range(len(parts) - 1):
                if parts[index:index + 2] == ['fits', 'now'] and (
                    index == 0 or parts[index - 1] != 'what'
                ):
                    return True
    return False


def check_badge(journey, label):
    until(lambda: fit_badge(journey.screen), label, journey.args.timeout)
    shutil.copyfile(journey.screen.path, journey.root/f'{label}.png')
    journey.report['checks'][label] = sha256(journey.screen.path)


def desktop_rail(screen):
    position = screen.find('Calendar')
    return position and position[0] < 230 and position[1] < 300


def run(args, report):
    root = args.output
    os.chdir(root)
    env = {**os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
           'GSETTINGS_BACKEND': 'memory', 'OMP_THREAD_LIMIT': '1', 'TZ': 'UTC'}
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    with ExitStack() as stack:
        private_display(args, root, env, stack)
        for occupied in (False, True):
            case = 'occupied' if occupied else 'fits'
            child_env, profile = new_profile(root/case, env)
            scene(profile, occupied=occupied)
            db = profile/'easy'/'workspace.sqlite3'
            journey = Journey(args, root, child_env, stack, report)
            app = journey.open(f'{case}-home')
            journey.check(f'{case}-task-visible', 'Send the studio notes')
            before = until(lambda: stored_workspace(db), 'the first migrated revision')
            if occupied:
                journey.check('occupied-visible', 'Dentist appointment')
                sleep(0.6)
                if fit_badge(journey.screen):
                    raise RuntimeError('Today suggested a task during the Personal appointment.')
                if stored_workspace(db) != before:
                    raise RuntimeError('Availability calculation changed the workspace.')
            else:
                check_badge(journey, 'fits-compact')
                resize(journey.screen, (1440, 900))
                until(lambda: desktop_rail(journey.screen), 'the desktop Calendar rail', args.timeout)
                check_badge(journey, 'fits-desktop')
                if stored_workspace(db) != before:
                    raise RuntimeError('The inline task suggestion changed the workspace.')
                journey.tap('Send the studio notes')
                journey.check('fits-review', 'Mark done')
                journey.tap('Mark done')
                finished = until(lambda: completed(db), 'the saved completion')
                if finished['revision'] != before['revision'] + 1 or finished['quick_check'] != 'ok':
                    raise RuntimeError('Completion did not use one valid SQLite revision.')
                until(lambda: not fit_badge(journey.screen),
                      'Today to stop recommending the completed task', args.timeout)
                report['completed_revision'] = finished['revision']
            stop(app)
    report['status'] = 'passed'


def completed(database):
    state = stored_workspace(database)
    return state if state and state['document']['tasks'][0]['done'] else None


def main():
    p = ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--app-revision', required=True)
    p.add_argument('--deny-ip', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--display', type=int, default=156)
    p.add_argument('--xvfb', default='Xvfb')
    p.add_argument('--xdotool', default='xdotool')
    p.add_argument('--x11-capture', default='import')
    p.add_argument('--tesseract', default='tesseract')
    p.add_argument('--timeout', type=int, default=45)
    args = p.parse_args()
    args.output = args.output.resolve(strict=True)
    args.binary = args.binary.resolve(strict=True)
    args.deny_ip = args.deny_ip.resolve(strict=True)
    os.environ['TZ'] = 'UTC'
    tzset()
    report = {'status': 'failed', 'app_revision': args.app_revision, 'checks': {},
              'ip_sockets_blocked': True, 'aot_sha256': sha256(args.binary.parent/'lib/libapp.so')}
    try:
        run(args, report)
    except Exception as error:
        report['error'] = str(error)
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
