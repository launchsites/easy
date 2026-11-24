#!/usr/bin/env python3
"""Check native iCalendar rejection, reviewed export, and day navigation."""

from argparse import ArgumentParser
from contextlib import ExitStack
from datetime import date, timedelta
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from time import sleep, tzset

from local_inference import sha256
from native_persona_journey import private_display
from native_release_smoke import (
    click_at, choose_orbit, initial_profile, new_profile, resize, stored_workspace,
    swipe_next_day, get_window,
)
from native_voice_capture import Screen, start_child, until, command
from native_workspace_scale import stop


SOURCE = 'Canary schedule'
SERIES = 'Tansy planning'
OVERRIDE = 'Mint moved slot'
DESELECT = 'Orchid private test'
TITLE = 'Canary reviewed export.ics'


def fixture(day):
    marker = f'{day:%Y%m%d}T060000Z'
    recurrence = (f'UID:series@fixture.invalid', f'DTSTAMP:{marker}')

    def event(fields):
        return ['BEGIN:VEVENT', *fields, 'END:VEVENT']

    return '\r\n'.join([
        'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Easy//Native synthetic verification//EN',
        f'X-WR-CALNAME:{SOURCE}',
        *event([*recurrence, f'DTSTART;VALUE=DATE:{day:%Y%m%d}', 'RRULE:FREQ=DAILY;COUNT=3',
                f'SUMMARY:{SERIES}']),
        *event([*recurrence, f'RECURRENCE-ID;VALUE=DATE:{day + timedelta(days=1):%Y%m%d}',
                f'DTSTART;VALUE=DATE:{day + timedelta(days=1):%Y%m%d}', f'SUMMARY:{OVERRIDE}']),
        *event(['UID:deselected@fixture.invalid', f'DTSTAMP:{marker}',
                f'DTSTART;VALUE=DATE:{day:%Y%m%d}', f'SUMMARY:{DESELECT}']),
        'END:VCALENDAR', '',
    ]).encode()


def backing_state(database):
    state = stored_workspace(database)
    if state is None:
        return None
    records = state.pop('document').get('importedCalendars', [])
    if records:
        state['calendars'] = records
        return state
    return None


def run(args):
    root = args.output.resolve()
    env = {**os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
           'GSETTINGS_BACKEND': 'memory', 'OMP_THREAD_LIMIT': '1'}
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    env, profile = new_profile(root/'profile', env)
    initial_profile(profile)
    path = root/'synthetic-schedule.ics'
    path.write_bytes(fixture(date.today()))
    incomplete = root/'incomplete-calendar.ics'
    incomplete.write_bytes(b'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n')
    oversized = root/'oversized-calendar.ics'
    with oversized.open('wb') as content:
        content.truncate(4 * 1024 * 1024 + 1)
    database = profile/'easy'/'workspace.sqlite3'
    os.chdir(root)
    report = {'status': 'failed', 'app_revision': args.app_revision,
              'executable_sha256': sha256(args.binary),
              'aot_sha256': sha256(args.binary.parent/'lib/libapp.so'),
              'input_sha256': sha256(path), 'ip_sockets_blocked': True, 'checks': {}}
    try:
        with ExitStack() as stack:
            private_display(args, root, env, stack)

            def open_app(label, size):
                app = start_child(stack, env, root/f'{label}.log', args.deny_ip, args.binary)
                window = until(lambda: get_window(args, env, app), 'the Easy window', seconds=30)
                screen = Screen(args, root, env, window)
                screen.send('windowfocus', window)
                resize(screen, size)
                return app, screen

            def snap(label, text):
                point = until(lambda: screen.find(text), label, seconds=26)
                shutil.copyfile(screen.path, root/f'{label}.png')
                report['checks'][label] = sha256(screen.path)
                return point

            def find_picker(title):
                try:
                    matches = command(env, args.xdotool, 'search', '--onlyvisible',
                                      '--name', f'^{re.escape(title)}$').strip().splitlines()
                except subprocess.CalledProcessError:
                    return None
                return matches[0] if len(matches) == 1 else None

            def choose_open_file(path=None):
                picker = until(lambda: find_picker('Open File'), 'the GTK open dialog', seconds=20)
                command(env, args.x11_capture, '-window', picker, root/'open-picker.png')
                screen.send('windowfocus', picker)
                if path is None:
                    screen.send('key', 'Escape')
                else:
                    screen.send('key', 'ctrl+l')
                    sleep(0.4)
                    screen.send('type', '--delay', 23, str(path))
                    screen.send('key', 'Return')
                    sleep(2)
                    if find_picker('Open File'):
                        screen.send('key', 'Return')
                until(lambda: not find_picker('Open File'), 'the selected file', seconds=10)
                screen.send('windowfocus', screen.window)

            def wheel_to(day, *, forward):
                label = day.strftime('%a %b %-d')
                for _ in range(20):
                    point = screen.find(label)
                    if point and point[1] < 70:
                        return label
                    screen.move(220, 450)
                    screen.send('click', '--repeat', '4', '5' if forward else '4')
                    sleep(0.2)
                raise RuntimeError(f'Vertical scrolling did not reach {label}.')

            def settings_files():
                until(lambda: screen.find('Note to self'), 'Today before changing settings')
                screen.tap('Mode')
                until(lambda: screen.find('Gym'), 'the focus menu')
                sleep(0.5)
                screen.tap('Settings')
                until(lambda: screen.find('Focus modes'), 'the settings route')
                sleep(0.4)
                if not screen.find('Calendar files'):
                    screen.move(308, 618)
                    screen.send('click', '5', 'sleep', '.13', 'click', '5')
                screen.tap('Calendar files')
                snap('files-menu', 'Import or export events')

            app, screen = open_app('first', (390, 844))
            settings_files()
            screen.tap('Import or export events')
            until(lambda: screen.find('Calendar transfer'), 'the transfer route')
            sleep(0.65)
            snap('calendar-transfer', 'Preview dates')
            opening = until(lambda: stored_workspace(database), 'the initial SQLite revision')
            for source, checkpoint, message in (
                (None, 'cancelled-picker', 'Preview dates'),
                (incomplete, 'rejected-incomplete', 'Incomplete calendar document'),
                (oversized, 'rejected-oversized', 'selected file is too large'),
            ):
                click_at(screen, 101, 89)
                choose_open_file(source)
                snap(checkpoint, message)
                if stored_workspace(database) != opening:
                    raise RuntimeError(f'{checkpoint} mutated the stored workspace.')
            click_at(screen, 101, 89)
            choose_open_file(path)
            snap('preview', '3 occurrences')
            p = snap('preview-deselect-present', DESELECT)
            click_at(screen, *p)
            before = stored_workspace(database)
            if before is None or 'importedCalendars' in before['document']:
                raise RuntimeError('Import preview modified the workspace before confirmation')
            click_at(screen, 285, 797)
            snap('review-confirmed', 'Calendar imported')
            saved = until(lambda: backing_state(database), 'the reviewed import in SQLite')
            if (saved['quick_check'] != 'ok' or saved['counts'] != before['counts'] or
                saved['revision'] != before['revision'] + 1 or len(saved['calendars']) != 1):
                raise RuntimeError('Reviewed import did not store one calendar in one revision')
            record = saved['calendars'][0]
            if (record['name'] != SOURCE or record['document'].count('BEGIN:VEVENT') != 2 or
                'RRULE:FREQ=DAILY;COUNT=3' not in record['document'] or
                'RECURRENCE-ID;VALUE=DATE:' not in record['document'] or
                f'SUMMARY:{OVERRIDE}' not in record['document'] or
                'deselected@fixture.invalid' in record['document']):
                raise RuntimeError('The reviewed import changed recurrence or included an unchecked item')
            click_at(screen, 28, 28)
            snap('stored-source-list', SOURCE)
            screen.tap(SOURCE)
            until(lambda: screen.find('Calendar transfer'), 'the export route')
            sleep(0.5)
            snap('stored-source-transfer', 'Preview dates')
            click_at(screen, 255, 91)
            picker = until(lambda: find_picker('Save File'), 'the GTK save dialog', seconds=20)
            command(env, args.x11_capture, '-window', picker, root/'save-picker.png')
            screen.send('windowfocus', picker)
            screen.send('key', 'ctrl+a')
            destination = root/TITLE
            screen.send('type', '--delay', 20, str(destination))
            screen.send('key', 'Return')
            until(destination.is_file, 'the native export file', seconds=20)
            screen.send('windowfocus', screen.window)
            snap('export-confirmed', 'Calendar exported')
            if destination.read_bytes() != record['document'].encode():
                raise RuntimeError('Export differs from the reviewed recurring calendar')
            stop(app)
            path.unlink()
            app, screen = open_app('reopened', (390, 844))
            until(lambda: screen.find('Note to self'), 'Today on reopening', seconds=20)
            choose_orbit(screen, 108, 693)
            snap('day-one', SERIES)
            if screen.find(DESELECT):
                raise RuntimeError('The unchecked event appears on the visible calendar')
            today = date.today()
            label = today.strftime('%a %b %-d')
            until(lambda: (point := screen.find(label)) and point[1] < 70,
                  'the actual first calendar heading', seconds=20)
            vertical_next = wheel_to(today + timedelta(days=1), forward=True)
            snap('vertical-day-two', vertical_next)
            snap('vertical-override', 'Mint moved')
            vertical_back = wheel_to(today, forward=False)
            snap('vertical-back', vertical_back)
            # Touch-like lateral swipe input should still work after vertical scrolling.
            swipe_next_day(screen)
            snap('day-two-override', 'Mint moved')
            swipe_next_day(screen)
            snap('day-three', SERIES)
            if backing_state(database) != saved:
                raise RuntimeError('Reopening the calendar changed its stored data')
            stop(app)
            report.update(status='passed', revision=saved['revision'], recurrence_occurrences=3,
                          override_preserved=True, unchecked_event_excluded=True,
                          cancelled_picker_and_invalid_inputs_saved_no_revisions=True,
                          oversized_fixture_bytes=oversized.stat().st_size,
                          vertical_calendar_day_change_and_return=True,
                          exact_export_sha256=sha256(destination), unchanged_restart_digest=saved['digest'])
    except Exception as error:
        report['error'] = str(error)
    (root/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    p = ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--app-revision', required=True)
    p.add_argument('--deny-ip', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--xvfb', default='Xvfb')
    p.add_argument('--xdotool', default='xdotool')
    p.add_argument('--display', type=int, default=194)
    p.add_argument('--x11-capture', default='import')
    p.add_argument('--tesseract', default='tesseract')
    args = p.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.deny_ip = args.deny_ip.resolve(strict=True)
    args.output = args.output.resolve(strict=True)
    os.environ['TZ'] = 'UTC'
    tzset()
    raise SystemExit(run(args))
