#!/usr/bin/env python3
"""Drive a synthetic personal day in the native Linux review release."""

from argparse import ArgumentParser
from contextlib import ExitStack
from datetime import date, datetime, time, timedelta
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
from time import sleep, tzset

from PIL import Image, ImageDraw, PngImagePlugin

from local_inference import sha256
from native_release_smoke import (
    PHONE, LIVE_WORKOUT, WORKOUT_CAPTURE, WORKOUT_TASK, choose_orbit, click_at,
    initial_profile, new_profile, get_window, resize, stored_workspace,
    captured_workout_state, resume_live_fixture, reveal_record, swipe_next_day,
)
from native_voice_capture import Screen, command, start_child, until
from native_workspace_scale import stop


EVENT_NAME = 'Orchard review'
MEAL_NAME = 'Saffron breakfast bowl'
FOOD_NAME = 'Cooked oats fixture'
MARKER = (241, 176, 84)


def prepare(profile, photo):
    initial_profile(profile, live_workout=True)
    preferences = profile/'shared_preferences.json'
    values = json.loads(preferences.read_text())
    workspace = json.loads(values['easy.workspace.v1'])
    workspace['nutrition'] = {'version': 1, 'meals': [], 'recipes': [], 'foods': [{
        'id': 'fixture-oats', 'name': FOOD_NAME, 'referenceAmount': 100,
        'referenceUnit': 'grams', 'source': 'Synthetic fixture label',
        'values': {'energyKcal': 100, 'proteinGrams': 4, 'carbsGrams': 19, 'fatGrams': 1},
    }]}
    values['easy.workspace.v1'] = json.dumps(workspace)
    preferences.write_text(json.dumps(values))
    image = Image.new('RGB', (400, 300), '#547775')
    drawing = ImageDraw.Draw(image)
    drawing.ellipse((55, 24, 345, 276), fill='#faf0de')
    drawing.ellipse((83, 52, 317, 248), fill=MARKER)
    for x, y in ((126, 89), (185, 111), (226, 162)):
        drawing.ellipse((x, y, x + 30, y + 30), fill='#93567c')
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text('Fixture', 'Synthetic image without personal data')
    image.save(photo, pnginfo=metadata)


def verify_timed_event(state, tomorrow):
    events = [item for item in state['document']['events'] if item['title'] == EVENT_NAME]
    if not events:
        return False
    start, end = (datetime.fromisoformat(events[0][field]) for field in ('start', 'end'))
    if (len(events) != 1 or bool(events[0].get('allDay')) or
            start.replace(tzinfo=None) != datetime.combine(tomorrow, time(14)) or
            end.replace(tzinfo=None) != datetime.combine(tomorrow, time(14, 45))):
        raise RuntimeError('Time capture changed the date, endpoints or event count.')
    return True


def verify_meal(state, image_hash, size, *, draft):
    records = state['document']['nutrition']['meals']
    if not records or (not draft and records[0].get('draft')):
        return False
    if (len(records) != 1 or bool(records[0].get('draft')) != draft or
            records[0]['photo'] != {'id': image_hash, 'mimeType': 'image/png',
                                    'format': 'png', 'byteLength': size}):
        raise RuntimeError('Meal draft did not preserve the exact photo reference.')
    if not draft:
        portions = records[0]['portions']
        if (records[0]['name'] != MEAL_NAME or len(portions) != 1 or
                portions[0]['food']['id'] != 'fixture-oats' or
                portions[0]['unit'] != 'grams' or portions[0]['amount'] != 150):
            raise RuntimeError('Meal did not keep the reviewed name and measured amount.')
    return True


class Journey:
    def __init__(self, args, root, env, stack, report):
        self.args, self.root, self.env, self.stack, self.report = args, root, env, stack, report
        self.screen = None

    def open(self, step):
        app = start_child(self.stack, self.env, self.root/f'{step}.log', self.args.deny_ip,
                          self.args.binary)
        window = until(lambda: get_window(self.args, self.env, app), 'the disposable app window', 45)
        self.screen = Screen(self.args, self.root, self.env, window)
        self.screen.send('windowfocus', window)
        resize(self.screen, PHONE)
        self.check(step, 'Note to self')
        return app

    def check(self, step, label):
        point = until(lambda: self.screen.find(label), step, self.args.timeout)
        shutil.copyfile(self.screen.path, self.root/f'{step}.png')
        self.report['checks'][step] = sha256(self.screen.path)
        return point

    def tap(self, label):
        point = until(lambda: self.screen.find(label), label, self.args.timeout)
        click_at(self.screen, *point)

    def text(self, text, *, submit=False):
        self.screen.send('type', '--delay', 20, text)
        if submit:
            self.screen.send('key', 'Return')

    def mode(self, label):
        self.tap('Mode')
        until(lambda: self.screen.find('Settings'), 'the Focus menu')
        sleep(0.45)
        self.tap(label)

    def gym(self, step, pending='Bench press'):
        self.mode('Gym')
        self.check(f'{step}-resumable', LIVE_WORKOUT)
        sleep(0.4)
        resume_live_fixture(self.screen, pending)
        self.check(f'{step}-live', 'Finish')

    def nutrition(self, step):
        self.mode('Health')
        until(lambda: self.screen.find('Meal log'), 'the health tools')
        sleep(0.4)
        self.tap('Meal log')
        self.check(step, 'Nutrition')

    def open_photo_fixture(self, photo):
        click_at(self.screen, 269, 813)

        def picker_window():
            try:
                matches = command(self.env, self.args.xdotool, 'search', '--onlyvisible',
                                  '--name', '^Open File$').strip().splitlines()
            except subprocess.CalledProcessError:
                return None
            return matches[0] if len(matches) == 1 else None

        picker = until(picker_window, 'the native image picker', self.args.timeout)
        self.screen.send('windowfocus', picker)
        self.screen.send('key', 'ctrl+l')
        sleep(0.45)
        self.text(str(photo), submit=True)
        sleep(1.5)
        if picker_window():
            self.screen.send('key', 'Return')
        until(lambda: not picker_window(), 'the GTK chooser to close')
        self.screen.send('windowfocus', self.screen.window)

    def check_photo_pixels(self, step):
        def visible_image():
            command(self.env, self.args.x11_capture, '-window', self.screen.window, self.screen.path)
            with Image.open(self.screen.path) as source:
                colors = source.convert('RGB').getcolors(1000000)
            return colors and any(count > 750 and color == MARKER for count, color in colors)

        until(visible_image, step, self.args.timeout)
        shutil.copyfile(self.screen.path, self.root/f'{step}.png')
        self.report['checks'][step] = sha256(self.screen.path)


def private_display(args, root, env, stack):
    path = root/'display.auth'
    path.touch(mode=0o600)
    env['DISPLAY'] = f':{args.display}'
    subprocess.run(
        ['xauth', '-q', '-f', str(path)],
        input=f"add {env['DISPLAY']} . {secrets.token_hex(16)}\n",
        text=True, env=env, check=True, timeout=5,
    )
    stack.callback(path.unlink, missing_ok=True)
    env['XAUTHORITY'] = str(path)
    display = start_child(stack, env, root/'xvfb.log', args.xvfb, env['DISPLAY'], '-screen', '0',
                          '1440x1000x24', '-nolisten', 'tcp', '-noreset', '-auth', path)

    def usable():
        if display.poll() is not None:
            raise RuntimeError('The disposable display did not start.')
        try:
            return command(env, args.xdotool, 'getdisplaygeometry')
        except subprocess.CalledProcessError:
            return None

    until(usable, 'the private X11 display')


def run(args, report):
    root = args.output.resolve()
    env = {**os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
           'GSETTINGS_BACKEND': 'memory', 'OMP_THREAD_LIMIT': '1', 'TZ': 'UTC'}
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    env, profile = new_profile(root/'profile', env)
    photo = root/'synthetic-meal.png'
    prepare(profile, photo)
    os.chdir(root)
    image_hash = sha256(photo)
    image_size = photo.stat().st_size
    attached = profile/'easy'/'attachments'/image_hash/'payload'
    database = profile/'easy'/'workspace.sqlite3'
    tomorrow = date.today() + timedelta(days=1)

    def snapshot():
        return stored_workspace(database)

    def checkpoint(expected, description):
        def acknowledged():
            state = snapshot()
            return state if state and expected(state) else None

        state = until(acknowledged, description, args.timeout)
        if state['quick_check'] != 'ok':
            raise RuntimeError(f'SQLite quick_check failed at {description}.')
        report['revisions'][description] = state['revision']
        return state

    with ExitStack() as stack:
        private_display(args, root, env, stack)
        journey = Journey(args, root, env, stack, report)
        app = journey.open('default-home')
        journey.check('default-home-upcoming', 'Upcoming today')
        journey.check('default-home-tasks', 'Tasks due today')
        baseline = checkpoint(lambda _: True, 'opening')
        screen = journey.screen

        choose_orbit(screen, 108, PHONE[1] - 151)
        journey.check('calendar-from-orbit', 'Tangerine booking')
        sleep(0.65)
        click_at(screen, PHONE[0] - 44, PHONE[1] - 38)
        journey.check('calendar-capture-open', 'Add event')
        journey.text(f'{EVENT_NAME} tomorrow', submit=True)
        journey.check('calendar-capture-start', 'Start time')
        journey.text('14:00', submit=True)
        journey.check('calendar-capture-end', 'End time')
        journey.text('14:00', submit=True)
        journey.check('calendar-capture-invalid-end', 'must be after the start')
        if snapshot() != baseline:
            raise RuntimeError('An incomplete calendar draft changed the workspace.')
        screen.send('key', 'ctrl+a')
        journey.text('14:45', submit=True)
        event = checkpoint(lambda state: verify_timed_event(state, tomorrow), 'calendar-saved')
        if event['revision'] != baseline['revision'] + 1:
            raise RuntimeError('Calendar capture used more than one save.')
        journey.check('calendar-next-day-event', 'Orchard')

        choose_orbit(screen, 52, PHONE[1] - 170)
        journey.check('home-for-gym', 'Note to self')
        sleep(0.65)
        journey.gym('gym')
        click_at(screen, PHONE[0] - 44, PHONE[1] - 38)
        journey.check('gym-capture', 'Capture review')
        journey.tap('Capture text')
        journey.text(WORKOUT_CAPTURE)
        sleep(0.3)
        screen.tap_footer()
        journey.check('gym-review', 'Mark these sets done')
        journey.tap('Mark these sets done')
        screen.tap_footer()
        screen.move(PHONE[0] - 6, 558)
        journey.check('gym-return', 'Finish')
        reveal_record(screen, 'Stretched')
        journey.check('gym-stretch-in-place', 'Stretched')
        workout = checkpoint(lambda _: captured_workout_state(database), 'gym-reviewed')
        if workout['revision'] != event['revision'] + 2:
            raise RuntimeError('Gym capture did not use one draft and one reviewed transaction.')

        click_at(screen, 28, 28)
        journey.check('gym-overview-after-capture', LIVE_WORKOUT)
        sleep(0.5)
        journey.nutrition('nutrition-from-gym')
        journey.open_photo_fixture(photo)
        journey.check('nutrition-draft', 'Meal photo attached')
        draft = checkpoint(lambda state: verify_meal(state, image_hash, image_size, draft=True), 'photo-draft')
        if draft['revision'] != workout['revision'] + 1 or sha256(attached) != image_hash:
            raise RuntimeError('The photo draft had an unexpected commit or altered its source.')
        journey.tap('Meal photo attached')
        journey.check_photo_pixels('nutrition-photo-visible')
        screen.send('key', 'Escape')
        journey.check('nutrition-editor-before-save', 'Meal name')
        journey.tap('Meal name')
        screen.send('key', 'ctrl+a')
        journey.text(MEAL_NAME)
        journey.tap('Add food')
        journey.check('nutrition-measured-portion', 'Amount eaten')
        sleep(0.55)
        click_at(screen, 69, 157)
        sleep(0.2)
        screen.send('key', 'ctrl+a')
        journey.text('150')
        journey.check('nutrition-entered-150', '150')
        click_at(screen, 303, 814)
        journey.check('nutrition-portion-added', 'Meal photo attached')
        click_at(screen, 303, 814)
        journey.check('nutrition-daily-total', 'Daily totals')
        saved = checkpoint(lambda state: verify_meal(state, image_hash, image_size, draft=False), 'meal-saved')
        if saved['revision'] != draft['revision'] + 1:
            raise RuntimeError('The final reviewed meal used more than one save.')

        app.kill()
        app.wait(timeout=10)
        photo.unlink()
        report['forced_process_exit'] = True
        app = journey.open('recovered-home')
        screen = journey.screen
        recovered = checkpoint(lambda _: True, 'reopened')
        if recovered != saved or sha256(attached) != image_hash:
            raise RuntimeError('The restarted profile lost or changed saved work.')
        if not verify_timed_event(recovered, tomorrow) or not captured_workout_state(database):
            raise RuntimeError('The calendar event or reviewed workout did not recover.')
        journey.check('recovered-work-task', WORKOUT_TASK)
        choose_orbit(screen, 108, PHONE[1] - 151)
        journey.check('recovered-calendar-today', 'Tangerine booking')
        sleep(0.55)
        swipe_next_day(screen)
        journey.check('recovered-calendar-event', 'Orchard')
        choose_orbit(screen, 52, PHONE[1] - 170)
        journey.check('recovered-home-from-calendar', 'Note to self')
        sleep(0.55)
        journey.gym('recovered-gym', pending='Treadmill')
        reveal_record(screen, 'Stretched')
        journey.check('recovered-gym-stretch', 'Stretched')
        click_at(screen, 28, 28)
        journey.check('recovered-gym-overview', LIVE_WORKOUT)
        sleep(0.55)
        journey.nutrition('recovered-nutrition')
        journey.tap('Saffron')
        journey.check('recovered-meal', 'Meal photo attached')
        journey.tap('Meal photo attached')
        journey.check_photo_pixels('recovered-photo')
        if snapshot() != saved:
            raise RuntimeError('Opening saved screens changed their workspace data.')
        report.update(attachment_sha256=image_hash, final_sqlite_digest=saved['digest'], status='passed')
        stop(app)


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--app-revision', required=True)
    parser.add_argument('--deny-ip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xvfb', default='Xvfb')
    parser.add_argument('--xdotool', default='xdotool')
    parser.add_argument('--x11-capture', default='import')
    parser.add_argument('--tesseract', default='tesseract')
    parser.add_argument('--display', type=int, default=155)
    parser.add_argument('--timeout', type=int, default=30)
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.deny_ip = args.deny_ip.resolve(strict=True)
    args.output = args.output.resolve(strict=True)
    os.environ['TZ'] = 'UTC'
    tzset()
    report = {'app_revision': args.app_revision, 'status': 'failed', 'ip_sockets_blocked': True,
              'executable_sha256': sha256(args.binary),
              'aot_sha256': sha256(args.binary.parent/'lib/libapp.so'),
              'checks': {}, 'revisions': {}}
    try:
        run(args, report)
    except Exception as error:
        report['error'] = str(error)
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
