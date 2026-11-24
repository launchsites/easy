"""Generate calendar-specific IANA continuation data from compiled TZif files."""

import argparse
import json
import re
from calendar import monthrange
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from zoneinfo._common import load_data


CUTOFF = 2145916800  # 2038-01-01T00:00:00Z
NAME = r"(?:[A-Za-z]{3,}|<[^>]+>)"
OFFSET = r"[+-]?\d{1,3}(?::\d{1,2}(?::\d{1,2})?)?"
FOOTER = re.compile(rf"^({NAME})({OFFSET})({NAME})({OFFSET})?,(M[^,]+),(M[^,]+)$")


def seconds(value):
    negative = value.startswith("-")
    pieces = (int(component) for component in value.lstrip("+-").split(":"))
    total = sum(amount * scale for amount, scale in zip(pieces, (3600, 60, 1)))
    return -total if negative else total


def rule_pieces(rule, before, after, label, daylight):
    match = re.fullmatch(rf"M(\d{{1,2}})\.([1-5])\.([0-6])(?:/({OFFSET}))?", rule)
    if match is None:
        raise ValueError(f"Unsupported TZif rule: {rule}")
    month, week, weekday = map(int, match.groups()[:3])
    day_shift, clock = divmod(seconds(match[4] or "2"), 86400)
    weekday = (weekday + day_shift + 6) % 7 + 1
    if day_shift == 0:
        return [(month, weekday, -1 if week == 5 else week, [], clock, before, after, label, daylight)]
    if month == 2:
        raise ValueError(f"Review Gregorian February handling for {rule}")
    month_end = monthrange(2001, month)[1]
    first_date = month_end - 6 if week == 5 else 1 + (week - 1) * 7
    by_month = defaultdict(list)
    for day in range(first_date, first_date + 7):
        moved = date(2001, month, day) + timedelta(days=day_shift)
        by_month[moved.month].append(moved.day)
    return [
        (moved_month, weekday, 0, days, clock, before, after, label, daylight)
        for moved_month, days in by_month.items()
    ]


def dart_row(row):
    return "(" + ", ".join(json.dumps(value) for value in row) + "),"


def generate(directory):
    recurring = defaultdict(list)
    extended = defaultdict(list)
    for path in sorted(directory.rglob("*")):
        if not path.is_file():
            continue
        zone = path.relative_to(directory).as_posix()
        with path.open("rb") as stream:
            if stream.read(4) != b"TZif":
                continue
            stream.seek(0)
            indexes, stamps, offsets, daylight, names, footer = load_data(stream)
        if b"," in footer:
            recurring[footer.decode()].append(zone)
        changes = []
        for index, stamp in enumerate(stamps):
            if index == 0 or stamp < CUTOFF:
                continue
            old, new = indexes[index - 1], indexes[index]
            if (offsets[old], daylight[old], names[old]) == (offsets[new], daylight[new], names[new]):
                continue
            changes.append((stamp, offsets[old], offsets[new], names[new], bool(daylight[new])))
        if changes:
            extended[tuple(changes)].append(zone)

    lines = [
        "// TZif continuation data from IANA tzdata 2026e, compiled with zic -b fat.",
        "// https://data.iana.org/time-zones/releases/tzdata2026e.tar.gz",
        "// SHA-256 b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652",
        "part of 'ics_zone_support.dart';",
        "",
        "const _recurringZones = <(List<String>, List<_ZoneRuleFields>)>[",
    ]
    for footer, zones in sorted(recurring.items()):
        match = FOOTER.fullmatch(footer)
        if match is None:
            raise ValueError(f"Unsupported TZif footer: {footer}")
        standard_name, standard_offset, daylight_name, daylight_offset, spring, autumn = match.groups()
        standard_offset = -seconds(standard_offset)
        daylight_offset = standard_offset + 3600 if daylight_offset is None else -seconds(daylight_offset)
        rows = [
            *rule_pieces(spring, standard_offset, daylight_offset, daylight_name.strip("<>"), True),
            *rule_pieces(autumn, daylight_offset, standard_offset, standard_name.strip("<>"), False),
        ]
        lines.extend([f"  ({json.dumps(sorted(zones))}, [", *map(dart_row, rows), "  ]),"])
    lines.extend([
        "];", "",
        "const _extendedZones = <(List<String>, List<_ZoneTransitionFields>)>[",
    ])
    for rows, zones in sorted(extended.items(), key=lambda entry: min(entry[1])):
        lines.extend([f"  ({json.dumps(sorted(zones))}, [", *map(dart_row, rows), "  ]),"])
    return "\n".join([*lines, "];", ""])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tzdir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.write_text(generate(args.tzdir), encoding="utf-8")
