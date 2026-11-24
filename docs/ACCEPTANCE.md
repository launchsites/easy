# Acceptance status

| Requirement | Development evidence | Remaining release gate |
|---|---|---|
| P01 Device-first start and preferences | Native Linux first-run choices, empty and sample workspaces, presets, display-name tool and restart. | First-run checks on mobile devices and desktop Apple. |
| P02 Today and navigation | Linux at twelve sizes, thumb orbit, Calendar swipe, keyboard search, focus surfaces and compact lists with large text. | Physical touch, assistive technology and device sign-off. |
| P03 Tasks and notes | Due times, nesting, repeats, reminders, prerequisites, Markdown and workspace links. Fault tests verify completion and revision-bound Undo. | Physical reminder delivery and broader platform accessibility. |
| P04 Calendar and deterministic planning | Mobile day and desktop week, DST, iCalendar, local repeats, saved travel, verified timing suggestions, reviewed day and week blocks and mocked Apple access. | Apple SDK, actual EventKit permissions and account interoperability. |
| P05 Focus and actual activity | Cross-focus capture, opt-in switches from confirmed events, and separate elapsed and planned time. | Physical timer and permission interruption tests. |
| P06 Review and habits | Daily availability, reflections, weekly and monthly history, local recurrence and reviewed rollover. | Long-session device history and notification checks. |
| P07 Workouts and health | Linux live workout including resolved set actuals, synthetic audio, history plots, weights, repeat plans and health visibility after restart. | Physical Gym and microphone journey on phones. |
| P08 Nutrition | Manual and photo drafts, checked units, recipes, offline food data and separate provider image review. | Live image models and a physical camera and weighed meal evaluation. |
| P09 Statistics and learning | Activity union, comparable outcomes, exact recent timing evidence, device ledger and aggregate exports have property and scale tests. | Live account spend and broader independent outcome evaluation. |
| P10 Capture and integrations | Reviewable text and speech, optional local or paid models, recent timing history, adaptive spending and local follow-up rules. | Real microphone use, paid billing, and broader model and device coverage. |
| Data integrity and recovery | SQLite migration, bounded history, authenticated original media, selected restores and interrupted write recovery. | Wider file system and device interruption checks before release. |
| Device sharing | Encrypted selected change files, independent approvals, paired journal reopen, conflicts, revocation and five-device ordering tests. | Physical peer interoperability. |
| Platform distribution | Linux native review builds plus Android review APKs and lint for ARMv7, ARM64 and x86-64. | Apple SDK builds, Android and Apple devices, and distribution signing. |

[Reproducible checks and measured results](TEST_EVIDENCE.md)
