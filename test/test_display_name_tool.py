import html
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from xml.etree import ElementTree as ET


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = Path('tool/set_display_name.py')
LABEL_FILES = (
    'lib/main.dart',
    'android/app/src/main/AndroidManifest.xml',
    'ios/Runner/Info.plist',
    'macos/Runner/Info.plist',
    'macos/Runner/Base.lproj/MainMenu.xib',
    'linux/runner/my_application.cc',
    'web/index.html',
    'web/manifest.json',
)
IDENTITY_FILES = (
    'android/app/build.gradle.kts',
    'ios/Runner.xcodeproj/project.pbxproj',
    'macos/Runner/Configs/AppInfo.xcconfig',
    'linux/CMakeLists.txt',
)


class DisplayNameToolTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for relative in (SCRIPT, *LABEL_FILES, *IDENTITY_FILES):
            copy = self.root / relative
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / relative, copy)

    def _run_tool(self, *args, check=True):
        return subprocess.run(
            [sys.executable, str(self.root / SCRIPT), *args],
            check=check,
            capture_output=True,
            text=True,
        )

    def test_name_round_trip_and_identity(self):
        name = '?Café "Desk" & O\'Reilly \\ $5'
        manifest = self.root / LABEL_FILES[1]
        android_ns = '{http://schemas.android.com/apk/res/android}'
        original_android = ET.parse(manifest).find('application').attrib.copy()
        original_android.pop(f'{android_ns}label')
        self._run_tool(name)
        application = ET.parse(manifest).find('application')
        self.assertEqual(application.attrib.pop(f'{android_ns}label'), r'\?' + name[1:].replace('\\', '\\\\'))
        self.assertEqual(application.attrib, original_android)
        for relative in LABEL_FILES[2:4]:
            plist = plistlib.loads((self.root / relative).read_bytes())
            self.assertEqual(plist['CFBundleDisplayName'], name)
            self.assertEqual(plist['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        menu = ET.parse(self.root / LABEL_FILES[4])
        self.assertEqual(menu.find(".//window[@id='QvC-M9-y7g']").get('title'), name)
        self.assertEqual(menu.find(".//menuItem[@id='4sb-4s-VLi']").get('title'), f'Quit {name}')
        quoted = json.dumps(name, ensure_ascii=False)
        self.assertIn(f'gtk_window_set_title(window, {quoted});', (self.root / LABEL_FILES[5]).read_text())
        self.assertIn(f'<title>{html.escape(name)}</title>', (self.root / LABEL_FILES[6]).read_text())
        web = json.loads((self.root / LABEL_FILES[7]).read_text())
        self.assertEqual(web['name'], name)
        self.assertEqual(web['short_name'], name)
        self.assertEqual(web['start_url'], '.')
        dart_name = quoted.replace('$', r'\$')
        self.assertIn(f'defaultValue: {dart_name}', (self.root / LABEL_FILES[0]).read_text())
        for path in IDENTITY_FILES:
            self.assertEqual((self.root / path).read_bytes(), (PROJECT / path).read_bytes())

        self._run_tool('Second name')
        web = json.loads((self.root / LABEL_FILES[7]).read_text())
        self.assertEqual(web['name'], 'Second name')
        self.assertEqual(web['short_name'], 'Second name')

    def test_preview_and_missing_field_leave_sources_intact(self):
        before = {path: (self.root / path).read_bytes() for path in LABEL_FILES}
        self.assertIn('Would set', self._run_tool('--dry-run', 'Different').stdout)
        after = {path: (self.root / path).read_bytes() for path in LABEL_FILES}
        self.assertEqual(after, before)
        self.assertNotEqual(self._run_tool('Invalid\nName', check=False).returncode, 0)

        final = LABEL_FILES[-1]
        (self.root / final).write_text('{}')
        result = self._run_tool('Different', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(final, result.stderr)
        for path in LABEL_FILES[:-1]:
            self.assertEqual((self.root / path).read_bytes(), before[path])


if __name__ == '__main__':
    unittest.main()
