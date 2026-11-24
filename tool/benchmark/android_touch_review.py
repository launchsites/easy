"""Verify touch navigation and event capture on a disposable AOSP emulator."""

from datetime import datetime, time as wall_time, timedelta
from hashlib import sha256
import json
import re
import struct
import subprocess
import time
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

from android_meal_recovery_smoke import _snapshot, accessible_target


REMOTE_UI = '/data/local/tmp/easy-touch-review.xml'
RECTANGLE = re.compile(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
FULL_DATE = re.compile(r'^[A-Za-z]+, [A-Za-z]+ \d{1,2}, \d{4}(?=$|[,\n])')
CAPTURE_TITLE = 'Android touch review'
CAPTURE_LINE = f'{CAPTURE_TITLE} 10:05-10:25'


def app_nodes(document, package):
    return (
        node for node in ElementTree.fromstring(document).iter('node')
        if node.get('package') == package and node.get('enabled') == 'true'
    )


def bounds(node):
    match = RECTANGLE.fullmatch(node.get('bounds', ''))
    if match is None:
        return None
    x1, y1, x2, y2 = map(int, match.groups())
    return (x1, y1, x2, y2) if x2 > x1 and y2 > y1 else None


def center(rectangle):
    x1, y1, x2, y2 = rectangle
    return (x1 + x2) // 2, (y1 + y2) // 2


def floating_controls(document, package, width, height, density):
    """Find paired thumb buttons when UIAutomator omits Flutter tooltips."""
    left = accessible_target(document, package, 'Navigate')
    right = accessible_target(document, package, 'Add item')
    if left and right:
        return left, right
    candidates = set()
    for node in app_nodes(document, package):
        rectangle = bounds(node)
        if rectangle is None or node.get('clickable') != 'true':
            continue
        x1, y1, x2, y2 = rectangle
        x, y = center(rectangle)
        edge = min(x, width - x) / density
        if (y > height * .78 and 32 <= edge <= 68 and
                44 <= (x2 - x1) / density <= 68 and 44 <= (y2 - y1) / density <= 68):
            candidates.add((x, y))
    left_points = [left] if left else [point for point in candidates if point[0] < width / 2]
    right_points = [right] if right else [point for point in candidates if point[0] > width / 2]
    pairs = [
        (start, end) for start in left_points for end in right_points
        if abs(start[1] - end[1]) <= 5
    ]
    return max(pairs, key=lambda pair: (pair[0][1], -pair[0][0], pair[1][0])) if pairs else None


def calendar_day(document, package):
    """Read the full date of Calendar's date-picker button."""
    dates = set()
    for node in app_nodes(document, package):
        if node.get('clickable') != 'true' or not bounds(node):
            continue
        for attribute in ('text', 'content-desc'):
            if match := FULL_DATE.match(node.get(attribute, '')):
                try:
                    dates.add(datetime.strptime(match[0], '%A, %B %d, %Y').date())
                except ValueError:
                    continue
    return next(iter(dates)) if len(dates) == 1 else None


def capture_field(document, package, value=None):
    for node in app_nodes(document, package):
        if (node.get('class') == 'android.widget.EditText' and
                (value is None or node.get('text') == value) and (rectangle := bounds(node))):
            return rectangle
    return None


def capture_submit(document, package, field):
    if point := accessible_target(document, package, 'Add event'):
        return point
    x1, y1, x2, y2 = field
    candidates = set()
    for node in app_nodes(document, package):
        if node.get('class') == 'android.widget.Button' and node.get('clickable') == 'true':
            if rectangle := bounds(node):
                x, y = center(rectangle)
                if x1 + (x2 - x1) * .80 < x <= x2 and y1 <= y <= y2:
                    candidates.add((x, y))
    return next(iter(candidates)) if len(candidates) == 1 else None


def navigation_method(help_text):
    if not re.search(r'(?m)^\s*tap\s+<', help_text):
        raise RuntimeError('ADB could not read the disposable device’s touch capabilities.')
    if re.search(r'(?m)^\s*draganddrop\s+<', help_text):
        return 'held-draganddrop'
    if re.search(r'(?m)^\s*motionevent\s+<', help_text):
        return 'held-motionevent'
    return 'tap-menu-fallback'


def review_capture(before, after, selected_day, zone):
    if after is None or after['revision'] == before['revision']:
        return None
    original = before['document']
    changed = after['document']
    added = [event for event in changed['events'] if event['title'] == CAPTURE_TITLE]
    if (after['revision'] != before['revision'] + 1 or after['quick_check'] != 'ok' or
            len(added) != 1 or len(changed['events']) != len(original['events']) + 1 or
            [event for event in changed['events'] if event != added[0]] != original['events'] or
            {key: value for key, value in changed.items() if key != 'events'} !=
            {key: value for key, value in original.items() if key != 'events'}):
        raise RuntimeError('Touch capture did not save exactly one event and preserve the sample records.')
    event = added[0]
    start = datetime.fromisoformat(event['start'])
    end = datetime.fromisoformat(event['end'])
    if (event['allDay'] is not False or start.tzinfo is None or end.tzinfo is None or
            start.astimezone(zone) != datetime.combine(selected_day, wall_time(10, 5), zone) or
            end.astimezone(zone) != datetime.combine(selected_day, wall_time(10, 25), zone)):
        raise RuntimeError('Touch capture saved the event on a different date or at a different time.')
    return {'title': CAPTURE_TITLE, 'start': event['start'], 'end': event['end']}


def check_touch_review(adb, emulator, package, scratch, output):
    """Continue after the startup runner has verified the fresh AVD."""
    from android_emulator_smoke import PNG_HEADER, SERIAL, adb_run, wait_on_device

    def device(*arguments, **options):
        return adb_run(adb, *arguments, **options)

    def wait_value(probe, description):
        found = None

        def poll():
            nonlocal found
            found = probe()
            return found is not None

        wait_on_device(emulator, poll, description, 60)
        return found

    def view(probe, description):
        def check():
            dump = device('shell', 'uiautomator', 'dump', REMOTE_UI, check=False, timeout=12)
            if dump.returncode or 'dumped to:' not in dump.stdout.casefold():
                return None
            result = device('shell', 'cat', REMOTE_UI, check=False)
            if result.returncode:
                return None
            try:
                value = probe(result.stdout)
            except ElementTree.ParseError:
                return None
            if value:
                return value, result.stdout
            (output / 'last-ui.xml').write_text(result.stdout, encoding='utf-8')
            return None

        return wait_value(check, description)

    def touch(verb, *coordinates):
        device('shell', 'input', 'touchscreen', verb, *map(str, coordinates))

    def tap_label(label):
        point, _ = view(lambda document: accessible_target(document, package, label), f'{label!r} on screen')
        touch('tap', *point)

    images = {}

    def screenshot(name):
        pixels = subprocess.check_output([adb, '-s', SERIAL, 'exec-out', 'screencap', '-p'], timeout=15)
        if not pixels.startswith(PNG_HEADER) or len(pixels) < 24:
            raise RuntimeError('ADB did not return an Android screenshot.')
        (output / name).write_bytes(pixels)
        images[name] = sha256(pixels).hexdigest()
        return struct.unpack_from('>II', pixels, 16)

    output.mkdir(parents=True, exist_ok=True)
    remote = f'/data/user/0/{package}/files/easy/workspace.sqlite3'
    snapshot = scratch / 'touch-workspace.sqlite3'
    tap_label('Full')
    tap_label('Explore with samples')

    def samples():
        state = _snapshot(device, remote, snapshot)
        if not state or state['document'].get('workspaceSetup') != 'complete':
            return None
        records = [item for name in ('events', 'tasks', 'notes') for item in state['document'][name]]
        if (state['revision'] != 2 or state['quick_check'] != 'ok' or not all(state['counts'].values()) or
                not all(row['id'].startswith('sample-') for row in records) or
                not {'workouts', 'captureMedia'}.issubset(state['document']['features']['enabled'])):
            raise RuntimeError('Sample onboarding did not produce the expected Full synthetic workspace.')
        return state

    baseline = wait_value(samples, 'the durable sample workspace')
    _, today_tree = view(lambda document: accessible_target(document, package, 'Note to self'), 'Today after setup')
    width, height = screenshot('01-today.png')
    density_lines = re.findall(r'(?m)^\s*(?:Physical|Override) density:\s*(\d+)\s*$',
                               device('shell', 'wm', 'density').stdout)
    if not density_lines or int(density_lines[-1]) <= 0 or not 0 < width < height:
        raise RuntimeError('The review requires a measured portrait phone display.')
    density = int(density_lines[-1]) / 160
    controls = floating_controls(today_tree, package, width, height, density)
    if not controls:
        controls, _ = view(lambda document: floating_controls(document, package, width, height, density),
                           'the floating navigation and capture controls')
    launcher = controls[0]

    assistance = device('shell', 'input', check=False)
    method = navigation_method(assistance.stdout + assistance.stderr)
    print(f'Android touch navigation uses {method}.', flush=True)
    touch('tap', *launcher)
    target, _ = view(lambda document: accessible_target(document, package, 'Calendar'), 'Calendar in the orbit')
    if not (launcher[0] < target[0] and launcher[1] > target[1]):
        raise RuntimeError('Calendar is outside the expected radial navigation area.')
    screenshot('02-orbit.png')
    if method == 'tap-menu-fallback':
        touch('tap', *target)
    else:
        touch('tap', *launcher)
        time.sleep(.3)
        if method == 'held-draganddrop':
            touch('draganddrop', *launcher, *target, 1200)
        else:
            touch('motionevent', 'DOWN', *launcher)
            try:
                time.sleep(.5)
                touch('motionevent', 'MOVE', *target)
            finally:
                touch('motionevent', 'UP', *target)

    zone = ZoneInfo(device('shell', 'getprop', 'persist.sys.timezone').stdout.strip() or 'UTC')
    sample = next(item for item in baseline['document']['events'] if item['id'] == 'sample-review')
    initial_day = datetime.fromisoformat(sample['start']).astimezone(zone).date()
    first, _ = view(lambda document: calendar_day(document, package), 'the Calendar date-picker heading')
    if first != initial_day:
        raise RuntimeError('Calendar opened on a day other than the sample workspace’s Today.')
    screenshot('03-calendar.png')
    expected = first + timedelta(days=1)
    touch('swipe', width * 8 // 10, height // 2, width * 2 // 10, height // 2, 360)
    _, next_tree = view(lambda document: calendar_day(document, package) == expected, 'tomorrow after the calendar swipe')
    screenshot('04-following-day.png')
    controls = floating_controls(next_tree, package, width, height, density)
    if not controls:
        raise RuntimeError('Calendar did not keep the two floating controls after the day swipe.')
    touch('tap', *controls[1])
    view(lambda document: capture_field(document, package), 'the capture text field')
    device('shell', 'input', 'text', CAPTURE_LINE.replace(' ', '%s'))
    field, draft = view(lambda document: capture_field(document, package, CAPTURE_LINE),
                        'the exact typed event draft')
    screenshot('05-event-draft.png')
    submit = capture_submit(draft, package, field)
    if submit:
        touch('tap', *submit)
    else:
        device('shell', 'input', 'keyevent', 'KEYCODE_ENTER')

    captured = wait_value(lambda: review_capture(baseline, _snapshot(device, remote, snapshot), expected, zone),
                          'the single durable synthetic event')
    view(lambda document: calendar_day(document, package) == expected, 'Calendar after saving the event')
    screenshot('06-saved.png')
    report = {
        'android_api': 36,
        'device': 'disposable AOSP x86-64 emulator',
        'display_pixels': [width, height],
        'fixture': 'Full workspace with built-in samples',
        'setup_revision': baseline['revision'],
        'navigation_input': method,
        'calendar_day_before_swipe': first.isoformat(),
        'calendar_day_after_swipe': expected.isoformat(),
        'capture_submit': 'touch' if submit else 'enter key',
        'saved_revision': baseline['revision'] + 1,
        'event': captured,
        'screenshots_sha256': images,
    }
    (output / 'last-ui.xml').unlink(missing_ok=True)
    (output / 'touch-review.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return report
