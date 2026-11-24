# Acceptance status

| Requirement | Status at sustained-build start | Evidence or remaining gate |
|---|---|---|
| P01 Device-only start and module preferences | Partial | Local startup works. Presets, capability settings, and module disable behavior need implementation and verification. |
| P02 Today, calendar, tasks, notes, and navigation | Partial | Linux release through `19d8c09` and the mobile viewport widget suite cover the core routes. Physical phone verification and additional interaction coverage remain. |
| P03 Tasks, projects, and notes | Partial | Local task completion and note capture work. Rich fields, nesting, linking, reminders, and recurring tasks need separate checks. |
| P04 Calendar and deterministic scheduling | Partial | Day and wide-week navigation work. The new pure-Dart scheduler covers explicit availability, buffers, dependencies, effort, and split feasibility in `test/scheduling/planner_test.dart`. Acceptance UI, recurrence, providers, and deeper profiling remain. |
| P05 Focus views and activity logging | Partial | A mode switches the active view. Flutter tests cover Gym plans and session recovery. Multi-calendar membership, general activities, and actual-time review remain. |
| P06 Daily and weekly review and habits | Pending | Morning, evening, recurring, and historical review flows need implementation. |
| P07 Gym, fitness, and health | Partial | Once, weekdays, interval plans, cardio, strength sets, and done or skipped session rows were verified on Linux. Health review and device integrations remain. |
| P08 Nutrition | Pending | Manual tracking, local records, and bounded optional analysis need implementation. |
| P09 Statistics and learning | Pending | Confirmation-backed history, estimates, and editable preferences need implementation. |
| P10 Capture, automations, and integrations | Partial | Manual text capture and review of event times work. Cross-focus interpretation, audio, proposed commands, and provider integration have separate gates. |
| Data integrity and recovery | Partial | Existing local persistence supports restart. Transactional migration, backup, restore, and fault tests are in progress. |
| Pairing and sync | Pending | Peer trust, convergence, and recovery need implementation and adversarial verification before use with real data. |
| Accessibility and performance | Partial | Phone-width Flutter and native Linux interactions passed. Device, text-scale, soak, and concurrent model probes remain. |
| Platform release | Partial | Linux x86-64 release verified. Android builds and physical device testing, signed macOS and iOS verification, and distribution evidence remain. |

A pure component test verifies its contract. It does not verify the corresponding feature through every platform or release path.
