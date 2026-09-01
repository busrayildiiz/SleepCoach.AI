# SleepListView Refactor

## Goal

The goal is to reduce the responsibilities of the large `SleepListView` while preserving existing behavior and improving testability and maintainability.

## Completed Extractions

### SleepTimelineCalculator

Timeline-specific derived logic was extracted from `SleepListView` into a focused, non-UI calculator. It assembles semantic timeline items, including wake, nap, and bedtime entries; completed, active, upcoming, and predicted states; break-aware durations; and prediction fallbacks. Visual decisions remain in the View. Dedicated tests cover timeline ordering, breaks, ongoing sleep, states, predictions, and missing prediction data.

### SleepOverviewCalculator

Overview and statistical calculations were extracted into a pure calculator. It provides daily totals, day-over-day change, rolling averages, average nap duration, latest-nap delta, consistency, nap count, and goal progress. Dedicated tests preserve the existing date ranges, fallbacks, truncation, break handling, and clamping behavior.

### SleepRecordPersistence

Sleep-record `UserDefaults` encoding and decoding was extracted into a small injectable persistence adapter. It was extracted to isolate storage mechanics while preserving the existing legacy `"sleepRecords"` key and notification behavior. Dedicated tests cover valid, missing, and invalid data, save ordering and values, and successful-save notifications.

### DailyWakeRecordPersistence

Daily wake-record `UserDefaults` encoding and decoding was extracted into a small injectable persistence adapter. It was extracted to isolate storage mechanics while leaving wake-time normalization, replacement, and ongoing-night business logic in `SleepListView`. Dedicated tests cover valid, missing, and invalid data, save ordering and values, and successful-save notifications.

## Persistence Compatibility

- `"sleepRecords"` remains the key used by `SleepListView` and `SleepCoachOrchestrator`.
- `"sleep_records_v1"` remains used by `SleepStore`.
- No persistence-key migration has been performed.
- `"dailyWakeRecords_v1"` remains unchanged.
- This separation is intentional for now to avoid accidental data loss or compatibility problems.

## Architectural Rules

- Refactoring must preserve existing behavior unless a deliberate behavior change is explicitly intended.
- Prefer small, focused extractions.
- Prefer pure, testable calculators for deterministic derived logic.
- Keep persistence mechanics separate from business/domain logic.
- Avoid unnecessary protocols and abstractions.
- Add focused tests around extracted responsibilities.
- Do not combine unrelated refactors into one change.
- Do not perform persistence migrations as part of structural refactoring.

## Current SleepListView Responsibilities

The following responsibilities intentionally remain in `SleepListView`:

- SwiftUI presentation
- User interaction
- Wake-time normalization and replacement of today’s record
- Ongoing-night closure logic
- Sheet and navigation routing
- Orchestrator lifecycle
- UI formatting and visual decisions

These responsibilities have not been extracted by the completed work documented here.

## Next Refactoring Candidates

Future candidates include:

- Remaining derived and business calculations
- Orchestrator lifecycle and dependency management
- Sheet and navigation routing
- Singleton reduction

These are future possibilities, not completed work.
