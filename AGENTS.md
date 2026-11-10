# Repository instructions

## Start small

- Read the task, `git status`, and any applicable nested `AGENTS.md` first.
- Read only task-relevant files and their direct callers/tests. Use targeted `rg` searches.
- Do not scan or audit the whole repository unless explicitly requested.
- Reuse existing documentation; do not generate large historical summaries.
- Make minimal, scoped changes. Avoid unrelated cleanup, dependencies, or CI changes.
- Preserve user records, storage keys, decoding compatibility, and public behavior unless the task explicitly changes them.

## Architecture and file map

App paths below are relative to `BabySleepTracker/`.

| Task area | Start here |
| --- | --- |
| Entry and routing | `BabySleepTrackerApp.swift`, `Services/AuthFlow.swift`, `Views/ContentView.swift` |
| Dashboard integration | `Views/SleepListView.swift`, `Views/SleepListSheetRouter.swift` |
| Accounting and state | `Models/SleepRecord.swift`, `Models/DailyWakeRecord.swift`, `Services/SleepOverviewCalculator.swift`, `Services/SleepTimelineCalculator.swift`, `Services/SleepStateCalculator.swift` |
| Wake-time mutations | `Services/SleepWakeTimeWorkflow.swift` |
| Persistence | `Services/SleepRecordPersistence.swift`, `Services/DailyWakeRecordPersistence.swift` |
| Predictions and coaching | `Services/SleepCoachOrchestrator.swift`, `Agents/Implements/`, `Agents/Protocols/`, `Services/SleepCoachLLMAgent.swift` |
| History and explanations | `Views/HistoryView.swift`, `Views/DayDetailView.swift`, `Views/InsightView.swift` |
| Regression tests and build | `BabySleepTrackerTests/` and `BabySleepTracker.xcodeproj/` at repository root |

SwiftUI is MVVM-inspired: views still own substantial state and persistence integration.
The main dashboard does not use `SleepListViewModel` as its state owner.
Deterministic agents produce the snapshot; Gemini adds coaching text.

Read further only as needed:
- [Architecture map](docs/ARCHITECTURE.md): active paths, legacy code, and build boundaries.
- [Product decisions](docs/PRODUCT_DECISIONS.md): confirmed policy versus implementation status.
- [Existing refactor guide](docs/architecture/sleep-list-view-refactor.md): extraction boundaries and storage compatibility.
- [README](README.md): product overview and screenshots.

## Product and data safety

- Check implementation status on the selected branch; a confirmed decision is not proof it is implemented.
- Preserve the confirmed accounting and entitlement decisions in `docs/PRODUCT_DECISIONS.md`.
- Do not silently change learning thresholds, subscription rules, or timestamp ownership.
- Use explicit reference dates/calendars in new calculation logic. Preserve observed versus inferred data.
- If required behavior is ambiguous, ask before inventing a rule; continue independent work when possible.
- Do not migrate storage or consolidate legacy implementations as incidental cleanup.

## Validation and handoff

- For behavior changes, add focused XCTest regression tests in the directly related suite.
- Fix invalid fixtures or outdated expectations with evidence; do not weaken assertions to get green tests.
- Use isolated defaults and deterministic dates/calendars where relevant.
- Run only the affected tests first, using the shared `BabySleepTracker` Xcode scheme and an available simulator.
- Xcode/iOS tests require macOS and Xcode. If unavailable, state exactly which checks could not run.
- Never claim tests passed unless actually executed. Syntax checks are not compilation or XCTest.
- Review the final diff and report changed files, actual test results, and remaining risks briefly.
- Do not automatically commit, push, create a pull request, or merge. Do so only when explicitly requested.
