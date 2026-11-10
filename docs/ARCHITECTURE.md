# Architecture map

Verified against `main` at `d860622`. Paths below are relative to `BabySleepTracker/`
unless stated otherwise. This maps current code, not planned features.

## Active runtime path

`BabySleepTrackerApp` → `RootView` (`Services/AuthFlow.swift`) → `ContentView`
→ tracking, history, and coaching views.

| Area | Active components and responsibilities |
| --- | --- |
| UI/state | `Views/SleepListView.swift` owns local records, wake records, sheets, notification subscriptions, and generation coalescing. `Views/SleepListSheetRouter.swift` wires sheets/callbacks. |
| Models | `Models/SleepRecord.swift` represents naps, nights, and parent-linked breaks; `Models/DailyWakeRecord.swift` stores morning anchors. Both use Codable. |
| Calculations | `Services/SleepOverviewCalculator.swift`, `Services/SleepTimelineCalculator.swift`, and `Services/SleepStateCalculator.swift` provide derived metrics, semantic timeline items, and active/inferred state. |
| Wake workflow | `Services/SleepWakeTimeWorkflow.swift` normalizes user-entered wake times, replaces the day's wake record, and closes a qualifying ongoing night. |
| Persistence | `Services/SleepRecordPersistence.swift` uses `sleepRecords`; `Services/DailyWakeRecordPersistence.swift` uses `dailyWakeRecords_v1`. Saves post NotificationCenter updates. Views and the orchestrator also contain direct UserDefaults access. |
| Orchestration | `Services/SleepCoachOrchestrator.swift` is a shared, main-actor ObservableObject with injectable agents. It loads records/profile, builds predictions/quality reports, publishes `OrchestratedSnapshot`, and manages LLM requests/cache. On this main baseline, generation also auto-closes stale ongoing records. |
| Deterministic agents | `Agents/Implements/`: phase, pattern, daytime, night, nap transition, overtired calculation, age calculation, and `DefaultInsightAgent`. Interfaces/profile data are in `Agents/Protocols/`; age profiles cover 4–24 months. |
| LLM | `Services/SleepCoachLLMAgent.swift` calls Gemini for coaching over deterministic outputs. The orchestrator owns request tokens/cancellation and cached responses; `Config/APIConfig.swift` reads the configured key. |
| Forms/history | `Views/AddRecordView.swift` uses `AddRecordViewModel` but constructs saved records in the view. `Views/HistoryView.swift`, `Views/DayDetailView.swift`, and `Views/InsightView.swift` retain their own derived logic. |

This is MVVM-inspired, not a strict view → view-model → repository architecture.
The deterministic agents are ordinary Swift services, not autonomous LLM agents.
For detailed extraction contracts, reuse the [existing refactor guide](architecture/sleep-list-view-refactor.md).

## Legacy or unused paths

| Component | Verified distinction |
| --- | --- |
| `Services/InsightAgent.swift` | Old duplicate types/incompatible API; not the active app target implementation. The Xcode source entry resolves to `Agents/Implements/InsightAgent.swift` (`DefaultInsightAgent`). Do not compile both indiscriminately. |
| `ViewModels/SleepListViewModel.swift` | Included in the app target with dedicated test source files, but not used by the main dashboard. Defaults to `MockSleepAPI`; its `SleepStore` writes `sleep_records_v1`, a separate key. |
| `ViewModels/DayDetailViewModel.swift` | Included in the app target with dedicated test source files; not the current `DayDetailView` state owner. |
| `Memory/SleepMemoryStore.swift` | Included in the app target with no references in the inspected active UI/orchestrator path; it does not centralize all persistence despite its comment. |
| `Models/SegmentKind.swift` | Alternative `SleepSession`/`SleepSegment` representation; active tracking persists `[SleepRecord]`. |
| `BabySleepTracker.xcdatamodeld` | Included in the project, but current app entry/persistence paths do not configure a Core Data stack. |

Do not remove, activate, migrate, or consolidate these paths incidentally.

## Implementation boundaries

- Current main groups daily totals by session start date; it does not contain the separate interval-union `SleepAccounting` implementation from the fix branch.
- Personalized phase currently uses 14 tracked days; the confirmed seven-recent-valid-day policy is pending.
- Local authentication/onboarding flags are routing scaffolding, not remote authentication.
- Premium styling exists; subscription entitlements, purchase enforcement, and first-free-summary tracking are pending.
- Cloud sync and longitudinal learned-model/LLM memory are not established by this architecture.
- See [product decisions](PRODUCT_DECISIONS.md) for precise confirmed behavior and branch-specific accounting status.

## Build and tests

- Repository-root `BabySleepTracker.xcodeproj` contains the app, XCTest target, and shared `BabySleepTracker` scheme with coverage enabled.
- Build settings specify iOS 16.2 and Swift 5 language mode; the resolved Google Generative AI Swift package is 0.5.6.
- Repository-root `BabySleepTrackerTests/` contains agent, model, calculator, persistence, workflow, and orchestrator suites. Open only suites relevant to the task.
- Use Xcode on macOS for iOS compilation/XCTest. File presence or syntax parsing does not establish a passing test run.
- [README](../README.md) provides the broader overview and screenshots; use code and the status notes above when older diagrams or roadmap text differ.
