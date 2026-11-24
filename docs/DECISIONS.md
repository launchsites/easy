# Engineering decisions

## One workspace and several focus views

A mode changes what a view emphasizes. It carries no authentication or authorization meaning. A user can search across the workspace and capture a task, note, event, meal, or workout while any mode is active. Allow each focus view to include several calendars. Preserve the underlying account and event identity, and require explicit selection of a writable destination for external edits.

## Proposals and committed changes

Keep capture interpretation and scheduling separate from writes. An interpreter emits typed proposals tied to the captured input and workspace revision. It has no database authority. Availability is explicit. A scheduler can propose only within that availability and around fixed commitments. Acceptance rechecks the current workspace before committing a change.

## Existing data and platform boundaries

Import existing local records without clearing the legacy keys. Verify writes, restore, and interrupted operations separately. Keep optional model files outside the app bundle. Measure real local inference on the available host and label CPU and memory constraints, actual hardware, and unsupported device claims.
