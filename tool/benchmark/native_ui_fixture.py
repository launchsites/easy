#!/usr/bin/env python3
"""Create an isolated Linux legacy-preferences fixture for UI stress tests."""

import argparse
from datetime import date, datetime, time, timedelta
import json
from pathlib import Path


CATEGORIES = ("work", "study", "personal", "gym")
EVENT_DAYS = 3660
TASKS = 3100
NOTES = 1300


def workspace(today):
    events = []
    for index in range(EVENT_DAYS):
        day = today - timedelta(days=EVENT_DAYS - index - 1)
        for slot in range(2):
            start = datetime.combine(day, time(hour=9 + slot * 4, minute=15))
            events.append({
                "id": f"stress-event-{index}-{slot}",
                "title": f"Synthetic appointment {index}-{slot}",
                "start": start.isoformat(),
                "end": (start + timedelta(minutes=45)).isoformat(),
                "category": CATEGORIES[(index + slot) % len(CATEGORIES)],
                "allDay": False,
                "location": None,
            })

    tasks = []
    for index in range(TASKS):
        day = today + timedelta(days=index % 30 - 16)
        tasks.append({
            "id": f"stress-task-{index}",
            "title": f"Synthetic task {index}",
            "category": CATEGORIES[index % len(CATEGORIES)],
            "date": None if index % 3 == 0 else day.isoformat(),
            "done": index % 4 == 0,
            "estimatedMinutes": 15 + index % 75,
        })

    notes = [{
        "id": "stress-home-note",
        "title": "Synthetic note to self",
        "body": "This workspace is generated for repeatable UI stress testing.",
        "updated": today.isoformat(),
        "noteToSelf": True,
    }]
    for index in range(NOTES):
        notes.append({
            "id": f"stress-note-{index}",
            "title": f"Synthetic reading note {index}",
            "body": ("Generated benchmark text with no real records. " * 20).strip(),
            "updated": (today - timedelta(days=index % 365)).isoformat(),
            "category": CATEGORIES[index % len(CATEGORIES)],
            "noteToSelf": False,
        })
    return {"events": events, "tasks": tasks, "notes": notes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xdg_data_home", type=Path, help="unused temporary directory")
    parser.add_argument("--today", type=date.fromisoformat, default=date.today())
    args = parser.parse_args()
    profile = args.xdg_data_home / "app.launchsites.easy"
    profile.mkdir(parents=True)
    data = workspace(args.today)
    fixture = {"easy.workspace.v1": json.dumps(data, separators=(",", ":"))}
    target = profile / "shared_preferences.json"
    with target.open("x") as output:
        json.dump(fixture, output)
    print(f"{target}  {target.stat().st_size} bytes")
    print(" ".join(f"{key}={len(items)}" for key, items in data.items()))


if __name__ == "__main__":
    main()
