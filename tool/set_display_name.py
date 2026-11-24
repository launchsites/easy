#!/usr/bin/env python3
"""Set Easy's visible app label in a local checkout."""

import argparse
import html
import json
from pathlib import Path
import re
import sys
import tempfile
import unicodedata

_QUOTED = r""""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"""


def _replace(text, pattern, value, path):
    start, old_value, end = pattern
    updated, count = re.subn(
        f"({start})({old_value})({end})",
        lambda match: match[1] + value + match[3],
        text,
    )
    if count != 1:
        raise ValueError(f"Expected one display label in {path}, found {count}.")
    return updated


def _edits(root, name):
    xml_name = html.escape(name, quote=True)
    quoted = json.dumps(name, ensure_ascii=False)
    android_name = name.replace("\\", "\\\\")
    if android_name.startswith(("@", "?")):
        android_name = "\\" + android_name
    plist_field = (r"<key>CFBundleDisplayName</key>\s*<string>", r"[^<]*", "</string>")

    fields = {
        "lib/main.dart": [
            (
                (
                    r"\bconst\s+appName\s*=\s*String\.fromEnvironment\(\s*'APP_NAME',\s*defaultValue:\s*",
                    _QUOTED,
                    r",?\s*\);",
                ),
                quoted.replace("$", r"\$"),
            ),
        ],
        "android/app/src/main/AndroidManifest.xml": [
            (
                (r'<application\b[^>]*?\bandroid:label="', r'[^"<>]*', '"'),
                html.escape(android_name, quote=True),
            ),
        ],
        "ios/Runner/Info.plist": [(plist_field, xml_name)],
        "macos/Runner/Info.plist": [(plist_field, xml_name)],
        "macos/Runner/Base.lproj/MainMenu.xib": [
            (
                (
                    r'<(?:menuItem|menu|window)\b[^<>]*?\btitle="',
                    r'[^"<>]*',
                    r'"[^<>]*?\bid="' + re.escape(element_id) + '"',
                ),
                prefix + xml_name,
            )
            for element_id, prefix in (
                ("1Xt-HY-uBw", ""),
                ("uQy-DD-JDr", ""),
                ("5kV-Vb-QxS", "About "),
                ("Olw-nP-bQN", "Hide "),
                ("4sb-4s-VLi", "Quit "),
                ("QvC-M9-y7g", ""),
            )
        ],
        "linux/runner/my_application.cc": [
            ((r"\bgtk_window_set_title\(window,\s*", _QUOTED, r"\);"), quoted),
        ],
        "web/index.html": [
            (("<title>", r"[^<]*", "</title>"), xml_name),
            ((r'<meta name="apple-mobile-web-app-title" content="', r'[^"<>]*', '"'), xml_name),
        ],
        "web/manifest.json": [
            ((rf'(?m:^[ \t]*"{key}"\s*:\s*)', _QUOTED, r"(?=\s*[,}])"), quoted)
            for key in ("name", "short_name")
        ],
    }

    updates = {}
    for relative_path, replacements in fields.items():
        path = root / relative_path
        original = path.read_bytes().decode("utf-8")
        updated = original
        for pattern, replacement in replacements:
            updated = _replace(updated, pattern, replacement, relative_path)
        if updated != original:
            updates[path] = (original.encode("utf-8"), updated.encode("utf-8"))
    return updates



def _write_updates(updates):
    staged = {}
    written = []
    try:
        for path, (_, content) in updates.items():
            with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
                temporary = Path(output.name)
                staged[path] = temporary
                output.write(content)
            temporary.chmod(path.stat().st_mode)
        for path, temporary in staged.items():
            temporary.replace(path)
            written.append(path)
    except OSError:
        for path in reversed(written):
            path.write_bytes(updates[path][0])
        raise
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", help="Visible app name")
    parser.add_argument("--dry-run", action="store_true", help="List proposed file edits")
    args = parser.parse_args()
    name = args.name
    if not name.strip() or any(
        unicodedata.category(character) in {"Cc", "Cs", "Zl", "Zp"}
        or character in "\ufffe\uffff"
        for character in name
    ):
        parser.error("Use a single-line display name.")
    if "${" in name or "$(" in name:
        parser.error("The name contains a platform build-setting placeholder.")

    root = Path(__file__).resolve().parents[1]
    try:
        updates = _edits(root, name)
        if not args.dry_run:
            _write_updates(updates)
    except (OSError, ValueError) as error:
        sys.exit(str(error))
    for path in updates:
        print(path.relative_to(root))
    print(f"{'Would set' if args.dry_run else 'Set'} the display name to {name!r}.")


if __name__ == "__main__":
    main()
