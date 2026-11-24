# Calendar time-zone interchange

Easy includes one `VTIMEZONE` per named clock in an authored iCalendar export. Historical offsets and recorded future exceptions come from IANA 2026e. Annual rules come from the same release's TZif continuations, including the daylight-saving changes after 2037 and their local onset times. Floating clock times, all-day dates, and UTC times retain their original value types. [IANA 2026e source](https://data.iana.org/time-zones/releases/tzdata2026e.tar.gz) · [RFC 5545, VTIMEZONE](https://www.rfc-editor.org/rfc/rfc5545.html#section-3.6.5)

Imported named times use the file's own definition when supplied. A matching private definition can use fixed transition dates or supported annual rules and can share a name with a built-in zone. Easy preserves the physical definition block, including folding and property order, for valid UTF-8 inputs. Invalid UTF-8 split at a physical fold is normalized by the compatibility reader. Unsupported rules and conflicting transitions produce an explicit import preview error.

Events marked free in Apple Calendar or carrying a valid `TRANSP:TRANSPARENT` iCalendar property stay on the agenda and leave the time available for planning. An ordinary repeating occurrence uses its series property. An imported exception needs its own explicit transparent property. Missing or invalid transparency keeps the event on the busy timeline.

## Verification run

The Linux AOT clock matched Python's `zoneinfo` on 849,924 UTC offsets across all 597 compiled zone names. Samples cover monthly checkpoints through year 9998 and points one second before, at, and after 2037–2040 changes. Separately, `python-dateutil` read 12 exported definitions and matched 4,608 local-noon offsets, including Lord Howe's half-hour change, Cairo's month boundary, and Gaza's future exceptions. Curl and zic were used to compile the official test data. These checks used synthetic records.

The Flutter suite checks preservation of real physical folding, identity of recurring rows and exceptions, legacy fold-inside-scalar imports, daylight-saving gaps, duplicated or unsupported definitions, and 600 seeded malformed inputs. File import is limited to 4 MiB, and expansion has separate content and occurrence limits.

## Repeat the comparison

Compile the source archive with `zic -b fat` and the `africa`, `antarctica`, `asia`, `australasia`, `europe`, `northamerica`, `southamerica`, `etcetera`, and `backward` files. The source archive SHA-256 is `b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652`.

```sh
dart compile exe test/fixtures/calendar_zones/probe.dart -o /tmp/easy-calendar-zone-probe
python3 test/fixtures/calendar_zones/oracle.py --tzdir /tmp/zoneinfo --probe /tmp/easy-calendar-zone-probe --external
```

The `--external` comparison uses `python-dateutil`. The TZif offset comparison uses only Python's standard library. Generate the Dart tables with `test/fixtures/calendar_zones/generate_data.py`, then format the output and compare it with `lib/calendar_sources/ics_zone_data.dart`. Update the pinned input and regenerate the comparison together when changing the timezone dependency.
