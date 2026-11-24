#!/usr/bin/env python3
"""Measure a dense workout against two Linux AOT bundles on one logical CPU."""

import argparse
from contextlib import ExitStack, closing
import ctypes
from datetime import datetime
import json
import os
from pathlib import Path
import selectors
import sqlite3
from statistics import median
from time import monotonic, sleep

from local_inference import sha256
from native_release_smoke import (
    PHONE, Screen, get_window, initial_profile, new_profile, resize, workout_documents,
)
from native_voice_capture import start_child, until
from native_workspace_scale import stop


EXERCISES = 1200
SETS = 6
EDITS = 6


def prepare_profile(profile):
    initial_profile(profile, live_workout=True)
    preferences = profile / 'shared_preferences.json'
    raw = json.loads(preferences.read_text())
    session = json.loads(raw['easy.gym-sessions.v1'][-1])
    exercises = [
        {
            'id': f'station-{index}',
            'name': f'Station {index}',
            'kind': 'strength',
            'sets': [
                {'id': f'set-{number}', 'weightKg': 50, 'reps': 8}
                for number in range(SETS)
            ],
        }
        for index in range(EXERCISES)
    ]
    session.update(
        exercises=exercises, plannedExercises=exercises,
        startedAt=datetime.now().isoformat(),
    )
    raw['easy.gym-sessions.v1'][-1] = json.dumps(session, separators=(',', ':'))
    preferences.write_text(json.dumps(raw, separators=(',', ':')))


class WorkoutArrow:
    """Observe the first Gym session frame in a small X11 window region."""

    def __init__(self, display, window):
        self.window = int(window)
        library = ctypes.CDLL('libX11.so.6')
        self.library = library
        library.XOpenDisplay.argtypes = [ctypes.c_char_p]
        library.XOpenDisplay.restype = ctypes.c_void_p
        library.XCloseDisplay.argtypes = [ctypes.c_void_p]
        library.XGetImage.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
            ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int,
        ]
        library.XGetImage.restype = ctypes.c_void_p
        library.XGetPixel.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        library.XGetPixel.restype = ctypes.c_ulong
        library.XDestroyImage.argtypes = [ctypes.c_void_p]
        self.display = library.XOpenDisplay(display.encode())
        if not self.display:
            raise RuntimeError('Could not connect to the disposable X11 server.')

    def close(self):
        self.library.XCloseDisplay(self.display)

    def visible(self):
        width, height = 12, 15
        image = self.library.XGetImage(
            self.display, self.window, 16, 20, width, height,
            ctypes.c_ulong(-1).value, 2,
        )
        if not image:
            raise RuntimeError('Could not read the Easy window.')
        try:
            return any(
                (self.library.XGetPixel(image, x, y) & 0xffffff) < 0x555555
                for y in range(height)
                for x in range(width)
            )
        finally:
            self.library.XDestroyImage(image)


def wait_timestamp(predicate, description):
    deadline = monotonic() + 15
    while monotonic() < deadline:
        if predicate():
            return monotonic()
        sleep(0.005)
    raise RuntimeError(f'Timed out waiting for {description}.')


def toggle_set(screen, database):
    times = []
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as observed:
        def revision():
            return observed.execute('SELECT MAX(revision) FROM revisions').fetchone()[0]

        # The first check warms the rendering and storage paths. The same
        # control clears that check, so subsequent edits exercise both states.
        for index in range(EDITS):
            prior = revision()
            started = monotonic()
            screen.send('mousedown', 1, 'mouseup', 1)
            saved = wait_timestamp(lambda: revision() > prior, 'the set revision')
            if revision() != prior + 1:
                raise RuntimeError('Expected one revision for one set edit.')
            session = workout_documents(database)['gym_sessions'][-1]
            expected = {'["station-0","set-0"]': 'done'} if index % 2 == 0 else {}
            if (session.get('progress', {}) != expected or
                    session['exercises'][0]['sets'][0]['reps'] != 8 or
                    session['plannedExercises'][0]['sets'][0]['weightKg'] != 50):
                raise RuntimeError('The wrong set or its original target changed.')
            times.append(round((saved - started) * 1000, 2))
            sleep(0.25)
    return times


def measure(args, stage, env, binary, label):
    environment, profile = new_profile(stage / label, env)
    prepare_profile(profile)
    database = profile / 'easy' / 'workspace.sqlite3'
    with ExitStack() as session:
        app = start_child(
            session, environment, stage / f'{label}.log',
            'taskset', '-c', str(args.cpu), binary,
        )
        window = until(lambda: get_window(args, environment, app), 'the Easy window')
        screen = Screen(args, stage, environment, window)
        screen.send('windowfocus', window)
        resize(screen, PHONE)
        screen.tap('Mode')
        screen.tap('Gym')
        _, preview_y = until(lambda: screen.find('Station 4'), 'the fifth preview exercise')
        arrow = WorkoutArrow(environment['DISPLAY'], window)
        session.callback(arrow.close)
        if arrow.visible():
            raise RuntimeError('The pre-workout screen already showed the session arrow.')
        screen.move(106, preview_y + 48)
        started = monotonic()
        screen.send('click', 1)
        render_time = wait_timestamp(arrow.visible, 'the live workout frame') - started
        until(lambda: screen.find('Finish'), 'the live workout header')
        screen.move(298, 154)
        sleep(0.35)
        edits = toggle_set(screen, database)
        screen.move(383, 560)
        screen.labels()
        (stage / f'{label}.png').write_bytes(screen.path.read_bytes())
        stop(app)
    return {
        'label': label,
        'open_ms': round(render_time * 1000, 2),
        'durable_edit_ms': edits,
        'warm_durable_edit_ms': median(edits[1:]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cpu', type=int, default=min(os.sched_getaffinity(0)))
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--xvfb', default='Xvfb')
    parser.add_argument('--xdotool', default='xdotool')
    parser.add_argument('--x11-capture', default='import')
    parser.add_argument('--tesseract', default='tesseract')
    args = parser.parse_args()
    if args.cpu not in os.sched_getaffinity(0) or args.repeats < 1:
        parser.error('Choose an available CPU and at least one repeat.')
    bundles = {'baseline': args.baseline.resolve(), 'candidate': args.candidate.resolve()}
    for binary in bundles.values():
        if not binary.is_file() or not (binary.parent / 'lib/libapp.so').is_file():
            parser.error('Each executable must belong to a Flutter Linux AOT bundle.')

    stage = args.output
    stage.mkdir(parents=True, exist_ok=True)
    env = {
        **os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
        'GSETTINGS_BACKEND': 'memory', 'OMP_THREAD_LIMIT': '1',
    }
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    results = {'baseline': [], 'candidate': []}
    with ExitStack() as stack:
        xvfb = start_child(
            stack, env, stage / 'xvfb.log', args.xvfb, '-displayfd', '1',
            '-screen', '0', '1440x1000x24', '-nolisten', 'tcp', '-noreset', '-ac', pipe=True,
        )
        with selectors.DefaultSelector() as selector:
            selector.register(xvfb.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=8):
                raise RuntimeError('Could not start the disposable X11 server.')
            env['DISPLAY'] = f':{int(xvfb.stdout.readline())}'
        for trial in range(args.repeats):
            order = ('baseline', 'candidate') if trial % 2 == 0 else ('candidate', 'baseline')
            for variant in order:
                result = measure(args, stage, env, bundles[variant], f'{variant}-{trial + 1}')
                results[variant].append(result)
                print(result, flush=True)

    report = {
        'cpu': args.cpu, 'width': PHONE[0], 'height': PHONE[1],
        'exercises': EXERCISES, 'sets_per_exercise': SETS,
        'builds': {
            name: {'exe': sha256(binary), 'aot': sha256(binary.parent / 'lib/libapp.so')}
            for name, binary in bundles.items()
        },
        'results': results,
        'medians': {
            name: {key: median(item[key] for item in group) for key in ('open_ms', 'warm_durable_edit_ms')}
            for name, group in results.items()
        },
    }
    (stage / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
