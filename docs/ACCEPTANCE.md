# Acceptance status

| Requirement | Development evidence | Remaining release gate |
|---|---|---|
| P01 Device-first start and preferences | Feature presets and independent focus and calendar controls preserve data across restart. | First-run flow and appearance coverage on native targets. |
| P02 Today and navigation | Native Home, Tasks and Settings at twelve sizes. Thumb orbit, Calendar swipe, keyboard search and contextual details have tests. | Expanded platform accessibility and device sign-off. |
| P03 Tasks and notes | Task nesting, prerequisites, deadlines, effort, completion history, Markdown organization and canonical record links are implemented. | Recurrence workflow integration, long-history speed and device reminder delivery. |
| P04 Calendar and deterministic planning | Mobile and desktop Calendar, ICS transfer, scoped event recurrence, explicit availability solver and reviewed Apple copies have dedicated checks. | Native Apple permissions and device review, travel preferences and deeper calendar performance. |
| P05 Focus and actual activity | Custom modes and cross-mode capture are integrated. Activity timers persist planned and actual spans separately. | Actual device timer interruption tests and optional contextual mode automation. |
| P06 Review and habits | Daily reflections, weekly and monthly history, habit schedules, pause ranges and reviewed rollover have local checks. | Native reminders and longer history review. |
| P07 Workouts and health | Workout templates, live sets, freestyle entries and dated health review have tests. | Native health permissions, compact accessibility and linked exercise history review. |
| P08 Nutrition | Manual and photo drafts, checked units and explicit provider review are implemented. | Food catalogue coverage, weighed meal evaluation and media retention. |
| P09 Statistics and learning | Confirmed activity union, comparable outcomes, duration evidence and aggregate export have property and scale tests. | Additional forecast provenance and app-wide evaluation. |
| P10 Capture and integrations | Durable voice, typed proposals, paid budgeting, local model validation and explicit Calendar writes have focused evidence. | Native microphone, automation integration, API/provider interoperability and device reviews. |
| Data integrity and recovery | SQLite migration, bounded history, authenticated backups, selected restore and an actual interruption test have evidence. | Portable media archives and broader disk fault tests. |
| Device sharing | The local encrypted journal supports approved peers, reviewed import, conflicts and replay protection. | Paired device workflow and transport validation before release. |
| Platform distribution | Native Linux build and offline flow, plus three Android AOT architectures, have run. | Android APK and lint, Apple builds, signed distribution, and physical devices. |

[Reproducible checks and measured results](TEST_EVIDENCE.md)
