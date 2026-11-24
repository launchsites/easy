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


def workspace(today, event_count=EVENT_DAYS * 2, task_count=TASKS, note_count=NOTES):
    events = []
    events_per_day, remaining_events = divmod(event_count, EVENT_DAYS)
    for index in range(EVENT_DAYS):
        day = today - timedelta(days=EVENT_DAYS - index - 1)
        slots = events_per_day + (index < remaining_events)
        for slot in range(slots):
            if slots == 2:
                minutes = (9 + slot * 4) * 60 + 15
            else:
                minutes = 7 * 60 + slot * (12 * 60) // max(1, slots)
            hour, minute = divmod(minutes, 60)
            start = datetime.combine(day, time(hour=hour, minute=minute))
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
    for index in range(task_count):
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
    for index in range(note_count):
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
    parser.add_argument("--events", type=int, default=EVENT_DAYS * 2)
    parser.add_argument("--tasks", type=int, default=TASKS)
    parser.add_argument("--notes", type=int, default=NOTES, help="extra reading notes")
    args = parser.parse_args()
    if min(args.events, args.tasks, args.notes) < 0:
        parser.error("fixture counts must be non-negative")
    profile = args.xdg_data_home / "app.launchsites.easy"
    profile.mkdir(parents=True)
    data = workspace(args.today, args.events, args.tasks, args.notes)
    fixture = {"easy.workspace.v1": json.dumps(data, separators=(",", ":"))}
    target = profile / "shared_preferences.json"
    with target.open("x") as output:
        json.dump(fixture, output)
    print(f"{target}  {target.stat().st_size} bytes")
    print(" ".join(f"{key}={len(items)}" for key, items in data.items()))


if __name__ == "__main__":
    main()
