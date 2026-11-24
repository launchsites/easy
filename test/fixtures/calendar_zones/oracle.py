"""Check the native-backed calendar clock and exported VTIMEZONE against TZif."""

import argparse
import io
import json
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


def timestamp(year, month=1, day=1):
    return int(datetime(year, month, day, tzinfo=timezone.utc).timestamp())


def offset(clock, second):
    return int(datetime.fromtimestamp(second, timezone.utc).astimezone(clock).utcoffset().total_seconds())


def transition_samples(clock):
    samples = []
    start = timestamp(2037)
    stop = timestamp(2041)
    interval = int(timedelta(days=2).total_seconds())
    before = offset(clock, start)
    while start < stop:
        end = min(start + interval, stop)
        after = offset(clock, end)
        if after != before:
            left, right = start, end
            while right - left > 1:
                middle = (left + right) // 2
                if offset(clock, middle) == before:
                    left = middle
                else:
                    right = middle
            samples.extend([right - 1, right, right + 1])
        start, before = end, after
    return samples


def exchange(probe, **request):
    probe.stdin.write(json.dumps(request) + "\n")
    probe.stdin.flush()
    reply = probe.stdout.readline()
    if not reply:
        raise RuntimeError("The Dart comparison process stopped early.")
    return json.loads(reply)


def check_exports(probe, zonefiles):
    from dateutil.tz import tzical

    observations = 0
    for name in [
        "Europe/Lisbon", "Europe/London", "Europe/Dublin", "America/New_York",
        "America/Santiago", "Africa/Cairo", "Asia/Gaza", "Asia/Jerusalem",
        "Australia/Lord_Howe", "Pacific/Apia", "Pacific/Norfolk", "Etc/UTC",
    ]:
        with zonefiles[name].open("rb") as stream:
            clock = ZoneInfo.from_file(stream)
        encoded = exchange(probe, name=name, export=True)
        external = tzical(io.StringIO(encoded)).get(name)
        for year in [2037, 2038, 2039, 2050, 2086, 2087, 2100, 2400]:
            for month in range(1, 13):
                for day in [1, 11, 21, 28]:
                    wall = datetime(year, month, day, 12)
                    expected = wall.replace(tzinfo=clock).utcoffset()
                    actual = wall.replace(tzinfo=external).utcoffset()
                    if actual != expected:
                        raise RuntimeError(f"{name} export {wall}: {actual} != {expected}")
                    observations += 1
    return observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tzdir", required=True, type=Path)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--external", action="store_true", help="Check VTIMEZONE in python-dateutil too.")
    arguments = parser.parse_args()
    files = {}
    for path in sorted(arguments.tzdir.rglob("*")):
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) == b"TZif":
                    files[path.relative_to(arguments.tzdir).as_posix()] = path
    months = [
        timestamp(year, month, day)
        for year in [*range(2037, 2090), 2100, 2101, 2400, 2500, 2999, 9998]
        for month in range(1, 13)
        for day in (1, 15)
    ]
    checked, comparisons, unknown = 0, 0, []
    with subprocess.Popen(
        [str(arguments.probe.resolve())],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    ) as probe:
        for name, path in files.items():
            with path.open("rb") as stream:
                clock = ZoneInfo.from_file(stream)
            samples = months + transition_samples(clock)
            actual = exchange(probe, name=name, samples=samples)
            if actual is None:
                unknown.append(name)
                continue
            if len(actual) != len(samples):
                raise RuntimeError(f"{name} returned an incomplete result.")
            for instant, observed in zip(samples, actual):
                expected = offset(clock, instant)
                if observed != expected:
                    raise RuntimeError(f"{name} {instant}: {observed} != {expected}")
            checked += 1
            comparisons += len(samples)
        exports = check_exports(probe, files) if arguments.external else None
        probe.stdin.close()
        if probe.wait(timeout=30):
            raise RuntimeError("The Dart comparison process failed.")
    print(json.dumps({
        "zone_names": checked,
        "unavailable_zone_names": unknown,
        "utc_offset_comparisons": comparisons,
        "export_offset_comparisons": exports,
    }, indent=2))


if __name__ == "__main__":
    main()
