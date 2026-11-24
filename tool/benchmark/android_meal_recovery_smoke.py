"""Replay a synthetic image_picker result in the disposable Android smoke app."""

from base64 import b64decode
from hashlib import sha256
import json
import re
import sqlite3
import struct
import time
from xml.etree import ElementTree

from native_ui_soak import workspace_state


_PHOTO_BYTES = b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAE0lEQVR4nGP8uCGkhwEKmBiQAAA76wKFcwHU0gAAAABJRU5ErkJggg=='
)
_PACKAGE_PATTERN = re.compile(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+')
_RECTANGLE = re.compile(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
_REMOTE_UI = '/data/local/tmp/easy-meal-recovery-ui.xml'
_REMOTE_PHOTO = '/data/local/tmp/easy-meal-recovery.png'
_REMOTE_PREFS = '/data/local/tmp/easy-meal-recovery.xml'


def accessible_target(document, package, label):
    """Find the center of the smallest live node matching an app action."""
    expected = label.casefold()
    candidates = []
    for node in ElementTree.fromstring(document).iter('node'):
        if node.get('package') != package or node.get('enabled') != 'true':
            continue
        labels = [node.get('text', ''), node.get('content-desc', '')]
        first_lines = [text.split('\n', 1)[0].split(', ', 1)[0] for text in labels]
        if not any(text.strip().casefold() == expected for text in first_lines):
            continue
        bounds = _RECTANGLE.fullmatch(node.get('bounds', ''))
        if bounds is None:
            continue
        left, top, right, bottom = map(int, bounds.groups())
        if right > left and bottom > top:
            area = (right - left) * (bottom - top)
            candidates.append((area, ((left + right) // 2, (top + bottom) // 2)))
    return min(candidates)[1] if candidates else None


def _picker_fixture(path):
    root = ElementTree.Element('map')
    files = ElementTree.SubElement(root, 'set', name='flutter_image_picker_image_path')
    ElementTree.SubElement(files, 'string').text = path
    ElementTree.SubElement(root, 'string', name='flutter_image_picker_type').text = 'image'
    ElementTree.SubElement(root, 'int', name='flutter_image_picker_image_quality', value='100')
    dimension = str(int.from_bytes(struct.pack('>d', 2560.0), 'big'))
    for edge in ('width', 'height'):
        ElementTree.SubElement(root, 'long', name=f'flutter_image_picker_max_{edge}', value=dimension)
    return ElementTree.tostring(root, encoding='utf-8', xml_declaration=True)


def _snapshot(device, remote, local):
    for suffix in ('-wal', '-shm', ''):
        local.with_name(local.name + suffix).unlink(missing_ok=True)
    if device('shell', 'test', '-f', remote, check=False).returncode:
        return None
    device('pull', remote, str(local))
    if not device('shell', 'test', '-f', remote + '-wal', check=False).returncode:
        device('pull', remote + '-wal', str(local) + '-wal')
    try:
        return workspace_state(local, include_document=True)
    except sqlite3.DatabaseError:
        # A live SQLite commit may race the copied database and WAL files.
        return None


def _verify_draft(state, original):
    if state is None:
        return None
    document = state['document']
    meals = document.get('nutrition', {}).get('meals', [])
    if not meals:
        return None
    if (state['revision'] != original['revision'] + 1 or state['quick_check'] != 'ok' or
            len(meals) != 1):
        raise RuntimeError('Meal recovery did not produce exactly one healthy durable revision.')
    meal = meals[0]
    photo = meal.get('photo', {})
    digest = photo.get('id', '')
    if (not re.fullmatch(r'[a-f0-9]{64}', digest) or meal['id'] != f'android-meal-{digest}' or
            meal.get('draft') is not True or meal.get('portions') != [] or
            photo.get('format') != 'png' or photo.get('mimeType') != 'image/png' or
            not isinstance(photo.get('byteLength'), int) or photo['byteLength'] <= 0):
        raise RuntimeError('The recovered Android meal changed the fixture or finalized it.')
    for key, expected in original['document'].items():
        if key != 'nutrition' and document.get(key) != expected:
            raise RuntimeError(f'Meal recovery unexpectedly changed {key}.')
    return meal


def check_meal_recovery(adb, emulator, package, launcher, scratch):
    """Run after the ordinary first-launch check on its rooted AOSP emulator."""
    from android_emulator_smoke import adb_run, wait_on_device

    if not _PACKAGE_PATTERN.fullmatch(package) or not re.fullmatch(
            re.escape(package) + r'/[A-Za-z_.][A-Za-z0-9_.]*', launcher):
        raise RuntimeError('The emulator test has an unexpected launcher.')

    def device(*args, **kwargs):
        return adb_run(adb, *args, **kwargs)

    if (device('shell', 'getprop', 'ro.kernel.qemu').stdout.strip() != '1' and
            device('shell', 'getprop', 'ro.boot.qemu').stdout.strip() != '1'):
        raise RuntimeError('Meal recovery requires the disposable emulator.')
    if device('shell', 'id', '-u').stdout.strip() != '0':
        raise RuntimeError('The disposable AOSP emulator must be rooted for the synthetic fixture.')

    def wait(probe, description, seconds=45):
        wait_on_device(emulator, probe, description, seconds)

    def find_action(label):
        device('shell', 'rm', '-f', _REMOTE_UI)
        device('shell', 'uiautomator', 'dump', _REMOTE_UI, check=False, timeout=12)
        result = device('shell', 'cat', _REMOTE_UI, check=False)
        if result.returncode:
            return None
        try:
            return accessible_target(result.stdout, package, label)
        except ElementTree.ParseError:
            return None

    def tap(label):
        point = None

        def target():
            nonlocal point
            point = find_action(label)
            return point

        wait(target, f'the {label!r} onboarding control')
        device('shell', 'input', 'tap', *map(str, point))

    base = f'/data/user/0/{package}'
    remote_workspace = f'{base}/files/easy/workspace.sqlite3'
    local_workspace = scratch / 'recovery-workspace.sqlite3'
    tap('Full')
    tap('Use my workspace')
    original = None

    def setup_complete():
        nonlocal original
        state = _snapshot(device, remote_workspace, local_workspace)
        if state is None or state['document'].get('workspaceSetup') != 'complete':
            return False
        if (state['revision'] != 2 or state['quick_check'] != 'ok' or any(state['counts'].values()) or
                not {'nutrition', 'captureMedia'}.issubset(state['document']['features']['enabled'])):
            raise RuntimeError('The emulator did not complete a fresh Full workspace.')
        original = state
        return True

    wait(setup_complete, 'the empty Full workspace')
    device('shell', 'am', 'force-stop', package)
    uid = device('shell', 'stat', '-c', '%u:%g', base).stdout.strip()
    if not re.fullmatch(r'\d+:\d+', uid) or uid.startswith('0:'):
        raise RuntimeError('The test could not identify the app sandbox owner.')

    private_photo = f'{base}/cache/easy-meal-recovery.png'
    prefs_dir = f'{base}/shared_prefs'
    private_prefs = f'{prefs_dir}/flutter_image_picker_shared_preference.xml'
    fixture_photo = scratch / 'fixture.png'
    fixture_prefs = scratch / 'image-picker-result.xml'
    fixture_photo.write_bytes(_PHOTO_BYTES)
    fixture_prefs.write_bytes(_picker_fixture(private_photo))
    device('push', str(fixture_photo), _REMOTE_PHOTO)
    device('push', str(fixture_prefs), _REMOTE_PREFS)
    if device('shell', 'test', '-d', prefs_dir, check=False).returncode:
        device('shell', 'mkdir', prefs_dir)
        device('shell', 'chown', uid, prefs_dir)
        device('shell', 'chmod', '700', prefs_dir)
        device('shell', 'restorecon', prefs_dir)

    def copy_fixture(source, destination):
        device('shell', 'cp', source, destination)
        device('shell', 'chown', uid, destination)
        device('shell', 'chmod', '600', destination)
        device('shell', 'restorecon', destination)

    def open_app():
        device('shell', 'am', 'start', '-W', '-n', launcher, timeout=45)

    copy_fixture(_REMOTE_PHOTO, private_photo)
    copy_fixture(_REMOTE_PREFS, private_prefs)
    open_app()
    saved = meal = None

    def recovered():
        nonlocal saved, meal
        state = _snapshot(device, remote_workspace, local_workspace)
        result = _verify_draft(state, original)
        if result is None:
            return False
        saved, meal = state, result
        return True

    wait(recovered, 'one locally recovered meal draft')
    pending = f'{base}/files/easy/android-meal-photo/photo'
    wait(lambda: device('shell', 'test', '!', '-f', pending, check=False).returncode == 0,
         'the completed recovery stage to clear')
    actual = scratch / 'recovered-payload.png'
    scaled = scratch / 'picker-scaled.png'
    remote_scaled = f'{base}/cache/scaled_easy-meal-recovery.png'
    device('pull', remote_scaled, str(scaled))
    scaled_bytes = scaled.read_bytes()
    if (not scaled_bytes.startswith(b'\x89PNG\r\n\x1a\n') or
            tuple(struct.unpack_from('>II', scaled_bytes, 16)) != (3, 2)):
        raise RuntimeError('The platform picker did not reproduce the synthetic image dimensions.')
    expected_hash = sha256(scaled_bytes).hexdigest()
    payload = f'{base}/files/easy/attachments/{expected_hash}/payload'
    device('pull', payload, str(actual))
    if (actual.read_bytes() != scaled_bytes or meal['photo']['id'] != expected_hash or
            meal['photo']['byteLength'] != len(scaled_bytes)):
        raise RuntimeError('The managed Android meal photo changed during recovery.')

    # Recreate the identical native result without replacing the original photo.
    # Android's asynchronous preference flush can leave this result after a kill.
    device('shell', 'am', 'force-stop', package)
    copy_fixture(_REMOTE_PREFS, private_prefs)
    open_app()

    def replay_processed():
        preferences = device('shell', 'cat', private_prefs, check=False)
        return (preferences.returncode == 0 and
                'flutter_image_picker_image_path' not in preferences.stdout and
                device('shell', 'test', '!', '-f', pending, check=False).returncode == 0)

    wait(replay_processed, 'the replayed picker result to clear')
    # The native plugin clears its own cache before the Dart callback starts.
    # Give the application time to finish the duplicate check and stage cleanup.
    time.sleep(1.5)
    if _snapshot(device, remote_workspace, local_workspace) != saved:
        raise RuntimeError('The same native picker result changed the saved meal or revision.')
    device('pull', payload, str(actual))
    if sha256(actual.read_bytes()).hexdigest() != expected_hash:
        raise RuntimeError('The recovered Android photo changed after the second launch.')

    report = {
        'scenario': 'synthetic Android image_picker saved-result replay',
        'first_revision': original['revision'],
        'recovered_and_replayed_revision': saved['revision'],
        'saved_workspace_sha256': saved['digest'],
        'photo_sha256': expected_hash,
        'photo_bytes': len(scaled_bytes),
        'original_fixture_sha256': sha256(_PHOTO_BYTES).hexdigest(),
        'one_local_draft': meal['draft'],
    }
    (scratch / 'meal-recovery.json').write_text(json.dumps(report, indent=2) + '\n')
    return report
