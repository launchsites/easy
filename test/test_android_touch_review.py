import copy
from datetime import date
from pathlib import Path
import sys
import unittest
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool' / 'benchmark'))
from android_touch_review import calendar_day, floating_controls, navigation_method, review_capture


PACKAGE = 'app.launchsites.easy'


def document(*rows):
    root = ElementTree.Element('hierarchy')
    for attributes in rows:
        ElementTree.SubElement(root, 'node', {
            'package': PACKAGE, 'enabled': 'true', 'clickable': 'true', **attributes,
        })
    return ElementTree.tostring(root, encoding='unicode')


class AndroidTouchReviewTest(unittest.TestCase):
    def test_floating_touch_controls_are_paired_even_without_tooltips(self):
        left = {'bounds': '[52,2130][200,2278]'}
        right = {'bounds': '[880,2130][1028,2278]'}
        other = {'bounds': '[52,2250][200,2398]', 'package': 'com.android.systemui'}
        clickable_content = {'bounds': '[50,1950][1030,2100]', 'text': 'Sample calendar'}
        self.assertEqual(
            floating_controls(document(left, right, other, clickable_content), PACKAGE, 1080, 2400, 2.625),
            ((126, 2204), (954, 2204)),
        )
        self.assertIsNone(floating_controls(document(left, other), PACKAGE, 1080, 2400, 2.625))

    def test_calendar_date_requires_a_single_live_clickable_heading(self):
        active = {'bounds': '[100,70][500,140]', 'content-desc': 'Monday, November 23, 2026\nChoose a date'}
        secondary = {'bounds': '[100,500][500,570]', 'text': 'Tuesday, November 24, 2026'}
        text = {**secondary, 'clickable': 'false'}
        self.assertEqual(calendar_day(document(active, text), PACKAGE), date(2026, 11, 23))
        self.assertIsNone(calendar_day(document(text), PACKAGE))
        self.assertIsNone(calendar_day(document(active, secondary), PACKAGE))

    def test_touch_fallback_requires_confirmed_capability_output(self):
        tap = '    tap <x> <y>\n'
        self.assertEqual(navigation_method(tap + '    draganddrop <x1>'), 'held-draganddrop')
        self.assertEqual(navigation_method(tap + '    motionevent <DOWN|UP|MOVE>'), 'held-motionevent')
        self.assertEqual(navigation_method(tap), 'tap-menu-fallback')
        with self.assertRaises(RuntimeError):
            navigation_method('adb: device offline')

    def test_exact_record_verification_fences_date_revision_and_other_records(self):
        before = {'revision': 2, 'document': {'events': [{'title': 'Sample'}], 'notes': []}}
        after = copy.deepcopy(before)
        after.update(revision=3, quick_check='ok')
        event = {
            'title': 'Android touch review', 'allDay': False,
            'start': '2026-11-24T15:05:00.000Z', 'end': '2026-11-24T15:25:00.000Z',
        }
        after['document']['events'].append(event)
        zone = ZoneInfo('America/New_York')
        self.assertIsNone(review_capture(before, before, date(2026, 11, 24), zone))
        self.assertEqual(review_capture(before, after, date(2026, 11, 24), zone)['start'], event['start'])
        with self.assertRaises(RuntimeError):
            review_capture(before, after, date(2026, 11, 23), zone)
        after['document']['notes'].append({'title': 'Unexpected write'})
        with self.assertRaises(RuntimeError):
            review_capture(before, after, date(2026, 11, 24), zone)


if __name__ == '__main__':
    unittest.main()
