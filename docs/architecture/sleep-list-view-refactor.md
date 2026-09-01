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

### SleepListSheetRouter

Sheet-specific routing and callback wiring was extracted from `SleepListView`. It composes the add-sleep, add-break, day-detail, and wake-time sheets while `SleepListView` retains state ownership, mutations, and persistence calls. Existing routes, filtering, ordering, edit flows, and callbacks are preserved.

### SleepWakeTimeWorkflow

Wake-time normalization and ongoing-night closure were extracted into a deterministic, non-UI workflow. It accepts explicit date, calendar, record, and persistence dependencies and returns updated records and persistence outcomes. It has no SwiftUI, `@State`, `NotificationCenter`, or `SleepCoachOrchestrator` dependency. Dedicated tests cover normalization, replacement, qualifying-night selection, exclusions, duration clamping, metadata preservation, and isolated persistence.

## Persistence Compatibility

- `"sleepRecords"` remains the key used by `SleepListView` and `SleepCoachOrchestrator`.
- `"sleep_records_v1"` remains used by `SleepStore`.
- No persistence-key migration has been performed.
- `"dailyWakeRecords_v1"` remains unchanged.
- This separation is intentional for now to avoid accidental data loss or compatibility problems.

## Orchestrator Production-Safety Work

The following bounded production-safety changes are complete:

- LLM requests use active-task tracking, request tokens, cancellation, and stale-result checks for published state and cache writes. `refreshLLM()` uses the same lifecycle boundary.
- LLM trigger detection compares the newly generated snapshot with the previously published snapshot.
- Sleep-record persistence owns its successful-change notification without a redundant Orchestrator notification.
- Notification-driven generation is coalesced at the `SleepListView` boundary while each persistence notification remains independently observable.
- Manual LLM refresh reuses the latest snapshot and the exact records generated with it.
- Cached alerts are explicitly removed when an accepted response has no alert.
- LLM cache entries carry a deterministic semantic source fingerprint and are classified internally as current, stale, or expired. The existing 24-hour expiry and offline fallback remain unchanged; trigger identity and snapshot generation timestamp are not part of semantic source identity.

These changes are bounded safety fixes, not a broad `SleepCoachOrchestrator` decomposition.

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
- `@State` ownership and assignment of workflow/calculator results
- UI lifecycle and callbacks
- User interaction integration
- Sheet presentation and routing integration
- Notification subscriptions
- Orchestrator lifecycle
- UI formatting and visual decisions

The wake-time workflow, raw persistence mechanics, timeline calculations, overview calculations, active/night-state calculations, and sheet-specific routing composition have been extracted as described above.

## Next Refactoring Candidates

The current roadmap is:

- Production-risk audit and bounded fixes in `SleepCoachOrchestrator` remain ongoing.
- Broader `SleepCoachOrchestrator` decomposition and dependency-management work is pending.
- Longitudinal LLM context and continuously updated pattern personalization remain product/architecture work, not completed features.
- A wake-anchored Sleep Day model remains a future domain decision; the investigated `SleepDayBoundaryResolver` work was rolled back and is not part of the current implementation.
- Singleton reduction remains pending.

These are future possibilities, not completed work.
